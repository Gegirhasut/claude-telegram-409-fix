## Summary

The Telegram channel goes permanently deaf after a session restart. It reports **connected · 4 tools**, outbound replies still send and return a `message_id`, but **no inbound message ever reaches a session again** for the life of that process.

The cause is self-inflicted. The polling retry loop stacks a second `getUpdates` long-poll on the same bot token, and the two race until Telegram 409s one of them. There is no competing consumer anywhere — the process races **its own** previous polling loop.

This is **deterministic**, not intermittent. It reproduces on every session restart.

| | |
|---|---|
| Plugin | `external_plugins/telegram` **0.0.6** |
| Claude Code | 2.1.207 |
| Runtime | bun 1.3.14 |
| Transport | long polling (no webhook — `getWebhookInfo` → `"url": ""`) |

## Reproduction

1. Run a session with the Telegram channel over long polling.
2. Restart Claude Code **while Telegram still holds the previous session's `getUpdates` long-poll open** (it stays open ~30–50s). The new process SIGTERMs the previous poller ([`server.ts:56-69`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L56-L69)) and begins polling immediately, without waiting for that long-poll to drain.
3. The new poller takes a `409 Conflict`.
4. The channel never receives another message.

The only trace is a `process.stderr.write` on a pipe nothing reads:

```
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s      # forever, ~9 per 30s
```

The message loss is measurable. Telegram's message ids are per-chat and sequential: the last id a session received was *N*, and a reply sent afterwards was assigned *N+11* — ten messages existed in that chat and reached nobody.

## Root cause

Two bugs in the polling retry loop ([`server.ts:999-1038`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L999-L1038)) compound.

**1. `bot.start()` is retried without `bot.stop()`.**

grammy leaves its polling loop running when `start()` rejects. The retry at [`server.ts:1002`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L1002) stacks a *second* long-poll on the same token. Telegram permits exactly one `getUpdates` consumer, so it 409s one of them — and **the survivor acks updates whose handlers never run**. That is where the messages go.

Confirmed at the socket level: the single plugin process holds **two** ESTABLISHED connections to `api.telegram.org`, both with growing byte counters.

**2. `onStart` resets `attempt = 0` ([`server.ts:1004`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L1004)) before the 409 can throw.**

`onStart` fires when polling *begins* — i.e. before `getUpdates` returns the 409. So by the time the error is caught, `attempt` is already back to 0, and the backoff at [`server.ts:1030`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L1030) — `Math.min(1000 * attempt, 15000)` — evaluates to **0 ms**. A hot retry loop with no delay.

It also makes the "409 persists after 8 attempts — Exiting" bailout at [`server.ts:1023`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L1023) permanently unreachable, since `attempt` is zeroed again on every restart before the next throw.

Once entered, the state is self-perpetuating and never recovers.

## Proof that no external competitor exists

The natural reading of a 409 is "another poller holds the token" — the plugin's own error message says exactly that. It is worth ruling out.

Freeze the poller (`SIGSTOP` — reversible, not a kill), wait for Telegram's in-flight long-poll to expire, then ask Telegram once whether anything else holds the token. No `offset` is passed, so this acknowledges nothing and drops no messages:

```bash
kill -STOP "$(cat ~/.claude/channels/telegram/bot.pid)"
sleep 60
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?timeout=0"
#  => 200 {"ok":true,"result":[]}     no 409  =>  nothing else is polling
kill -CONT "$(cat ~/.claude/channels/telegram/bot.pid)"
```

No 409 while the plugin's own poller is frozen ⇒ every 409 it reports is its own.

## Why `pending_update_count: 0` misleads

While the channel is deaf, `getWebhookInfo` reports `pending_update_count: 0`.

That reads as "nothing is stuck." It means the opposite: **something is draining the queue.** Updates are being fetched and acked by the stacked poller, then discarded before any handler runs. A zero pending count is exactly what you would see from a perfectly healthy bot *and* from this failure — so the one metric an operator would reach for cannot distinguish them. That is a large part of why this is hard to see from the outside.

## Patch

Two changes, both inside the retry loop:

- **Call `bot.stop()` before every retry of `bot.start()`**, so the old poll loop is torn down instead of left running and stacked on. (Uses the plugin's existing `Promise.resolve(bot.stop())` idiom from `server.ts:659`; grammy types `stop()` as `Promise<void>`.)
- **Don't reset `attempt` in `onStart`.** Track when polling actually started, and only refresh the backoff budget after a run that genuinely polled for 30s+. Keeping `attempt >= 1` floors the backoff at 1s and makes the 8-attempt bailout reachable — so a *real* external conflict now fails loudly instead of spinning forever.

```diff
--- a/external_plugins/telegram/server.ts
+++ b/external_plugins/telegram/server.ts
@@ -996,12 +996,13 @@ bot.catch(err => {
 // returned, and polling stopped permanently while the process stayed alive
 // (MCP stdin keeps it running). Outbound tools kept working but the bot was
 // deaf to inbound messages until a full restart.
+let startedAt = 0
 void (async () => {
   for (let attempt = 1; ; attempt++) {
     try {
       await bot.start({
         onStart: info => {
-          attempt = 0
+          startedAt = Date.now()
           botUsername = info.username
           process.stderr.write(`telegram channel: polling as @${info.username}\n`)
           void bot.api.setMyCommands(
@@ -1019,6 +1020,18 @@ void (async () => {
       if (shuttingDown) return
       // bot.stop() mid-setup rejects with grammy's "Aborted delay" — expected, not an error.
       if (err instanceof Error && err.message === 'Aborted delay') return
+      // grammy leaves its polling loop running when start() rejects. Retrying without
+      // stopping stacks a second getUpdates long-poll on the same token: Telegram allows
+      // one consumer, so it 409s one of them, and the survivor acks updates whose handlers
+      // never run. The bot goes deaf with no competing process anywhere — the 409s are its
+      // own. Tear the old loop down before retrying.
+      await Promise.resolve(bot.stop()).catch(() => {})
+      // Only a run that actually polled for a while earns a fresh backoff budget. Resetting
+      // in onStart (which fires before getUpdates can 409) made every retry immediate —
+      // delay = 1000 * 0 — and put the bailout below permanently out of reach. Keeping
+      // attempt >= 1 also floors the backoff at 1s.
+      if (startedAt && Date.now() - startedAt > 30_000) attempt = 1
+      startedAt = 0
       const is409 = err instanceof GrammyError && err.error_code === 409
       if (is409 && attempt >= 8) {
         process.stderr.write(
```

**Ready to cherry-pick**, based on `e14e8fe` — one commit, `server.ts` only, 14 insertions / 1 deletion:

- Commit: https://github.com/Gegirhasut/claude-plugins-official/commit/d6f73c2156a9e15f72ad1a19255a2c8136fba481
- Diff vs `main`: https://github.com/anthropics/claude-plugins-official/compare/main...Gegirhasut:claude-plugins-official:fix/telegram-409-poller-stacking

Verified with `tsc --noEmit --strict` against `grammy@1.44.0`.

I didn't open this as a PR because the repo auto-closes external PRs — happy to send one if a maintainer would rather have it that way.

## Second failure mode: an orphaned poller spins on EPIPE and survives SIGTERM

This is a **separate bug** from the stacking above, but the two feed each other. I hit it in the wild while verifying the patch.

When a session dies, its poller can be left orphaned — reparented to init, with its stdout/stderr pipe closed. From then on, every `process.stderr.write` in the plugin throws `EPIPE`. The uncaught-exception handler reports that error by writing it **to the same broken pipe**, which throws `EPIPE` again, which it reports again. It never terminates.

Measured on a real orphan before I killed it:

- **~74,000 failed `write()` calls in 5 seconds** — every single `write` syscall erroring.
- **~157,000 `telegram channel: uncaught exception: Error: EPIPE: broken pipe, write` messages in 30 seconds.**
- **One CPU core pegged at ~92% for 30 minutes**, until I reaped it by hand.
- **Zero connections to `api.telegram.org`** — it was far too busy failing to write to do any actual polling.

**It is immune to SIGTERM.** The shutdown handler ([`server.ts:652`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L652)) writes `telegram channel: shutting down` to stderr *before* it calls `bot.stop()`. On an orphan that write throws `EPIPE`, so the signal handler dies on its first line and never reaches the stop or the `process.exit(0)`. I confirmed this: I sent `SIGTERM`, the process survived. Only `SIGKILL` cleared it.

**This is what arms the 409.** The stale-holder reaper at [`server.ts:56-69`](https://github.com/anthropics/claude-plugins-official/blob/e14e8fe2c1fca5912d7389ba7e3a44149d36b5c8/external_plugins/telegram/server.ts#L56-L69) sends `SIGTERM` to the previous poller and then proceeds to start polling, **assuming the old process died**. Against an orphan in the EPIPE loop, it didn't. So a fresh session begins polling while a live orphan still holds the token — which is precisely the conflict that produces the `409` the retry loop then mishandles. Bug two creates the condition; bug one turns it into a permanent outage.

Suggested fixes, all independent of the patch above:

- **Guard every stderr write.** Swallow `EPIPE` (or check `process.stderr.writable` first). A logger that can throw — and whose error path logs — is a loop waiting to happen. This alone defuses the spin.
- **Stop the bot before logging in the shutdown path.** Call `bot.stop()` first, log after, so a dead pipe can't prevent a clean exit.
- **Make the reaper verify the kill.** After `SIGTERM`, poll for the pid actually being gone and escalate to `SIGKILL` after a short timeout, instead of assuming `SIGTERM` worked.

## Separate ask: surface a persistent 409 in `/mcp`

This failure is invisible by construction. The sole signal is a `process.stderr.write` to a pipe nothing reads, while the channel goes on advertising **connected · 4 tools** despite being deaf.

**I have now watched the channel report "connected · 4 tools" while deaf for two entirely independent reasons** — the stacked-poller 409 storm, and the orphaned EPIPE spin above. Two different root causes, the same silent, healthy-looking status. That is the strongest argument that the reporting itself is the bug: whatever is fixed underneath, the next cause will be just as quiet.

A poller that is **not actually consuming updates must not report healthy.** A repeated 409, an exited polling loop, zero connections to the Bot API — any of these should surface in the `/mcp` panel and degrade the channel's reported status. As it stands, the only way to discover any of them is to notice that people's messages are silently not arriving, which can take days.

That is worth fixing independently of the patch above: the patch removes *two* causes of a deaf channel, but a status that cannot distinguish "polling" from "not polling" will hide the third.

A smaller, related point: the startup handoff (SIGTERM the old poller, then immediately begin polling) races Telegram's in-flight long-poll *by design*. Even with this patch it costs a retry cycle on every restart. Waiting for the previous poller to exit — or treating the first 409 after startup as expected — would make the handoff clean.

## Workaround for anyone hitting this now

Write-up, the patch, and an idempotent preflight script that re-applies it after a plugin update (the plugin lives in a cache directory, so an update silently wipes local fixes):

https://github.com/Gegirhasut/claude-telegram-409-fix
