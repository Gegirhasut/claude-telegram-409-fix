## Summary

The Telegram channel goes permanently deaf after a session restart. It reports **connected · 4 tools**, outbound replies still send and return a `message_id`, but **no inbound message ever reaches a session again** for the life of that process.

The bugs below are about how the plugin **reacts** to a `409 Conflict`, and they hold regardless of what caused the first one. Whatever the trigger, the retry loop stacks a second `getUpdates` long-poll on the same token, the two race, and Telegram 409s one of them — so the plugin ends up manufacturing conflicts on top of the one it was trying to recover from, and **the survivor acks updates whose handlers never run**.

The channel reports **connected · 4 tools** throughout, for three independent reasons (a bailout that `return`s instead of exiting, a poller that never logs again once bailed out, and a `pending_update_count` of 0 that looks identical to health).

The reproduction below is **deterministic** — restart during an open long-poll and it happens every time.

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

## Why a 409 is hard to attribute

The natural reading of a 409 is "another poller holds the token" — the plugin's own error message says exactly that, and it names a *local* stray process. In practice an operator **cannot tell** who is holding the token, and the tools that look like they would settle it do not.

The obvious probe is to freeze the poller (`SIGSTOP` — reversible, not a kill), let Telegram's in-flight long-poll expire, and ask once whether anything else is consuming. No `offset` is passed, so it acks nothing and drops no messages:

```bash
kill -STOP "$(cat ~/.claude/channels/telegram/bot.pid)"
sleep 60
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?timeout=0"
#  => 200 {"ok":true,"result":[]}     no 409  -- but this does NOT mean "nothing else is polling"
kill -CONT "$(cat ~/.claude/channels/telegram/bot.pid)"
```

I ran exactly this and it came back clean. It was not conclusive, for two reasons:

- **It freezes the wrong set of processes.** `bot.pid` names only the *newest* poller. An orphaned poller — see the EPIPE/SIGTERM failure mode below — is by definition not the pid in that file, so the probe leaves it running and polling.
- **A remote or intermittent consumer can be idle at probe time.** A one-shot `getUpdates` samples a single instant. A poller that is between long-polls, backing off, or spinning on an error returns no 409 for that sample and resumes afterwards.

`getWebhookInfo` does not break the tie either: `pending_update_count` is **0** whether the bot is perfectly healthy or being silently drained by a competing consumer (see below).

**In my own case I could not determine who held the token.** The probe was clean; the channel was still deaf; `/revoke` in BotFather is what finally restored it — and a revoke invalidates the token for *every* holder, local or remote, so it identifies nobody. A local orphan and a second host are equally consistent with everything I observed.

That ambiguity is not a footnote — it is part of the bug. The plugin's error message asserts a local stray process, which sent me hunting locally; had the holder in fact been remote, no amount of local hunting could have found it. **And it argues for the patch rather than against it:** since an operator cannot establish who caused the first 409, the plugin must not respond to one by manufacturing more.

### There is no remote kill switch except `/revoke`

Worth stating explicitly, because it is not obvious: **the Bot API offers no call that evicts another `getUpdates` consumer.** `deleteWebhook`, `close`, `logOut` do not do it. If the holder is not a process you can reach, revoking the token in BotFather is the *only* way to break its grip — at the cost of invalidating it everywhere, including for you.

That belongs in the plugin's own error message. Today it names only causes you could kill locally — "stray `bun server.ts` process or a second session" — and stops there. If the holder is in fact somewhere you cannot reach, that message sends you hunting for a process that does not exist on your machine, and never mentions the one thing that would end it.

## Why `pending_update_count: 0` misleads

While the channel is deaf, `getWebhookInfo` reports `pending_update_count: 0`.

That reads as "nothing is stuck." It means the opposite: **something is draining the queue.** Updates are being fetched and acked by the stacked poller, then discarded before any handler runs. A zero pending count is exactly what you would see from a perfectly healthy bot *and* from this failure — so the one metric an operator would reach for cannot distinguish them. That is a large part of why this is hard to see from the outside.

## Patch

Three changes, all inside the retry loop:

- **Call `bot.stop()` before every retry of `bot.start()`**, so the old poll loop is torn down instead of left running and stacked on. (grammy types `stop()` as `Promise<void>`.)
- **Don't reset `attempt` in `onStart`.** Track when polling actually started, and only refresh the backoff budget after a run that genuinely polled for 30s+. Keeping `attempt >= 1` floors the backoff at 1s and makes the 8-attempt bailout reachable — so a conflict that really is someone else's now fails loudly instead of spinning forever.
- **`process.exit(1)` at the bailout instead of `return`.** A bare `return` left a live pid with zero Telegram sockets — a deaf zombie still reporting **connected · 4 tools**. Exiting makes the failure visible in `/mcp` and restartable.

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
@@ -1019,13 +1020,32 @@ void (async () => {
       if (shuttingDown) return
       // bot.stop() mid-setup rejects with grammy's "Aborted delay" — expected, not an error.
       if (err instanceof Error && err.message === 'Aborted delay') return
+      // bot.start() leaves its polling loop running when it rejects. Restarting
+      // without stopping stacks a second long-poll on the same token, and the
+      // two race: Telegram 409s one, the survivor acks updates the handlers
+      // never see. Whatever caused the first 409, retrying this way manufactures
+      // more of them. Always tear the old loop down before retrying.
+      await bot.stop().catch(() => {})
+
+      // Only a run that actually polled for a while earns a fresh backoff.
+      // Resetting on onStart made every 409 retry instantly (delay = 0) and put
+      // the 8-attempt bailout below permanently out of reach.
+      if (startedAt && Date.now() - startedAt > 30_000) attempt = 1
+      startedAt = 0
+
       const is409 = err instanceof GrammyError && err.error_code === 409
       if (is409 && attempt >= 8) {
         process.stderr.write(
           `telegram channel: 409 Conflict persists after ${attempt} attempts — ` +
-          `another poller is holding the bot token (stray 'bun server.ts' process or a second session). Exiting.\n`,
+          `another poller is holding the bot token (stray 'bun server.ts' process, a second session, ` +
+          `or the same token deployed on another host). Exiting.\n`,
         )
-        return
+        // `return` here only exited the retry loop. MCP stdin keeps the process alive, so the
+        // result was a live pid with zero Telegram sockets: outbound tools still worked, inbound
+        // was stone deaf, and nothing was logged ever again — a bailed-out poller is silent, so
+        // "quiet" reads as healthy. Exit for real: a dead MCP server is visible in /mcp and can
+        // be restarted; a deaf zombie holding stdin cannot be told from a working channel.
+        process.exit(1)
       }
       const delay = Math.min(1000 * attempt, 15000)
       const detail = is409
```

**Ready to cherry-pick**, based on `e14e8fe` — one commit, `server.ts` only, 23 insertions / 3 deletions:

- Commit: https://github.com/Gegirhasut/claude-plugins-official/commit/1f618b6291f49bc579fb0c3d0783d93dbeccef63
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

### The 8-attempt bailout `return`s instead of exiting — leaving a deaf zombie that looks healthy

The retry loop's give-up branch says `Exiting.` and then does not exit:

```ts
if (is409 && attempt >= 8) {
  process.stderr.write(`telegram channel: 409 Conflict persists after ${attempt} attempts — ...  Exiting.\n`)
  return   // ← leaves the LOOP. Nothing calls process.exit. MCP stdin keeps the process alive.
}
```

`return` exits the async IIFE, not the process. The MCP server keeps holding stdin, so the plugin lives on in a state that is worse than a crash:

- **live pid, zero sockets to `api.telegram.org`** — it is not polling and never will again;
- **outbound tools keep working** — `reply`, `react`, `edit_message` all succeed, so the channel feels alive from the agent's side;
- **inbound is stone deaf** — `/start` and `/status` get no answer, which is the tell: those are handled before any allowlist check, so silence there rules out an auth drop and points at the transport;
- **it never logs again.** A bailed-out poller is silent *by construction*. Silence is this bug's signature, which means every "no errors in the log" check reads it as healthy. My own verification script passed this exact state for an hour.

`/mcp` reports **connected · 4 tools** throughout. That is now the **third** independent cause I have watched produce a healthy-looking deaf channel, which I think settles the argument in the section below.

**Fix:** `process.exit(1)`. A dead MCP server is visible in `/mcp` and can be restarted; a zombie holding stdin cannot be told apart from a working channel. If the loop has genuinely given up, the process has no reason to exist.

**Also broaden the message.** It attributes the 409 to a `stray 'bun server.ts' process or a second session` — both *local*. In my case the competitor was the same bot token deployed on **another host entirely**, and that wording sent me hunting for a local orphan that did not exist. Local checks (`pgrep`, orphan sweeps) cannot see a remote holder; only `curl`ing `getUpdates` by hand and reading the 409 does. Suggest: `…(a stray poller, a second session, or the same token running on another host)`.

## Separate ask: surface a persistent 409 in `/mcp`

This failure is invisible by construction. The sole signal is a `process.stderr.write` to a pipe nothing reads, while the channel goes on advertising **connected · 4 tools** despite being deaf.

**I have now watched the channel report "connected · 4 tools" while deaf for three entirely independent reasons** — the stacked-poller 409 storm, the orphaned EPIPE spin above, and the bailed-out retry loop that `return`s without exiting. Three different root causes, the same silent, healthy-looking status. That is the strongest argument that the reporting itself is the bug: whatever is fixed underneath, the next cause will be just as quiet.

A poller that is **not actually consuming updates must not report healthy.** A repeated 409, an exited polling loop, zero connections to the Bot API — any of these should surface in the `/mcp` panel and degrade the channel's reported status. As it stands, the only way to discover any of them is to notice that people's messages are silently not arriving, which can take days.

That is worth fixing independently of the patch above: the patch removes *two* causes of a deaf channel, but a status that cannot distinguish "polling" from "not polling" will hide the third.

A smaller, related point: the startup handoff (SIGTERM the old poller, then immediately begin polling) races Telegram's in-flight long-poll *by design*. Even with this patch it costs a retry cycle on every restart. Waiting for the previous poller to exit — or treating the first 409 after startup as expected — would make the handoff clean.

## Workaround for anyone hitting this now

Write-up, the patch, and an idempotent preflight script that re-applies it after a plugin update (the plugin lives in a cache directory, so an update silently wipes local fixes):

https://github.com/Gegirhasut/claude-telegram-409-fix
