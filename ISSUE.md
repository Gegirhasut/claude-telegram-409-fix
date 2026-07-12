**Title:** Telegram channel is permanently deaf after a session restart — the poller stacks a second `getUpdates` loop and 409-storms itself, silently

---

### Environment

| | |
|---|---|
| Plugin | `claude-plugins-official/telegram` **0.0.6** |
| Claude Code | 2.1.207 |
| Runtime | bun 1.3.14 |
| OS | Ubuntu (Linux) |
| Transport | long polling (no webhook — `getWebhookInfo` → `"url": ""`) |

### Symptom

After a Claude Code session restart, the Telegram channel reports **connected · 4 tools** and
**outbound works** — a reply sends successfully and returns a `message_id`. But **inbound is silently
dead**:

- DMs show "delivered" in the Telegram app and never reach any session.
- `getWebhookInfo` → `pending_update_count: 0`.
- Nothing surfaces in the UI, the `/mcp` panel, or any log file.

The zero pending count is actively misleading. It reads as "nothing is stuck", but it means the
opposite: **something is draining the update queue**. Updates are fetched and discarded before any
handler runs.

The loss is visible in Telegram's message ids, which are per-chat and sequential: the last id a
session received was *N*, and a reply sent afterwards was assigned *N+11* — ten messages existed in
that chat and reached nobody.

This is **deterministic**, not intermittent. It recurs on every session restart.

### Reproduction

1. Run a session with the Telegram channel over long polling.
2. Restart Claude Code. The new `server.ts` SIGTERMs the previous poller (`server.ts:56–68`) and
   starts polling **immediately**, while Telegram still holds the previous `getUpdates` long-poll
   open for ~30–50s.
3. The new poller takes a `409 Conflict`.
4. The channel never receives another message for the life of the session.

The only trace is a stderr write on a pipe nothing reads:

```
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s      # forever, ~9 per 30s
```

### Root cause

Two bugs in the polling retry loop (`server.ts`, lines 999–1036) compound into a **self-inflicted**
409 storm. There is no competing consumer anywhere — the process races **its own** previous polling
loop over the single bot token.

**1. `bot.start()` is retried without `bot.stop()`.**
grammY leaves its polling loop running when `start()` rejects. The retry at `server.ts:1002` stacks a
*second* long-poll on the same token. Telegram permits exactly one `getUpdates` consumer, so it 409s
one of them — and **the survivor acks updates whose handlers never run**. That is where the messages
go. Confirmed at the socket level: the single plugin process holds **two** ESTABLISHED connections to
`api.telegram.org`, both with growing byte counters.

**2. `onStart` resets `attempt = 0` (`server.ts:1004`) *before* the 409 throws.**
The backoff at `server.ts:1030` is `Math.min(1000 * attempt, 15000)`, which therefore evaluates to
**0 ms** — a hot retry loop with no delay. It also makes the "409 persists after 8 attempts —
Exiting" bailout at **`server.ts:1023`** permanently unreachable, since `attempt` is zeroed again on
every restart before the next throw.

Once entered, the state is self-perpetuating and never recovers.

### Proof that no external competitor exists

Freeze the poller (`SIGSTOP` — reversible, not a kill), wait for Telegram's in-flight long-poll to
expire, then ask Telegram once whether anything else holds the token. No `offset` is passed, so this
acknowledges nothing and drops no messages:

```bash
kill -STOP "$(cat ~/.claude/channels/telegram/bot.pid)"
sleep 60
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?timeout=0"
#  => 200 {"ok":true,"result":[]}     no 409  =>  nothing else is polling
kill -CONT "$(cat ~/.claude/channels/telegram/bot.pid)"
```

No 409 while the plugin's own poller is frozen ⇒ every 409 it reports is its own.

### Proposed patch

```diff
--- a/server.ts
+++ b/server.ts
@@ -996,12 +996,13 @@
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
@@ -1019,6 +1020,19 @@
       if (shuttingDown) return
       // bot.stop() mid-setup rejects with grammy's "Aborted delay" — expected, not an error.
       if (err instanceof Error && err.message === 'Aborted delay') return
+      // bot.start() leaves its polling loop running when it rejects. Restarting
+      // without stopping stacks a second long-poll on the same token, and the
+      // two race: Telegram 409s one, the survivor acks updates the handlers
+      // never see. That is a self-inflicted 409 storm — the bot goes deaf with
+      // no competitor anywhere. Always tear the old loop down before retrying.
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
```

With this applied, the retry tears the old loop down first (nothing stacks), the backoff floors at
1s, and a *genuine* conflict reaches the bailout and fails loudly instead of spinning forever.

### Please also make the failure non-silent

This is invisible by construction: the sole signal is `process.stderr.write(...)` to a pipe nothing
reads, while the channel continues to advertise **connected · 4 tools** despite being deaf. A
repeated 409 — or any state in which the poller is not actually consuming updates — should surface
in the `/mcp` panel and degrade the channel's reported status, instead of being reported as healthy.

A smaller, related suggestion: the startup handoff (SIGTERM the old poller, then immediately begin
polling) races Telegram's in-flight long-poll by design. Even with the patch it costs a retry cycle
on every restart. Waiting for the previous poller to exit — or treating the first 409 after startup
as expected — would make the handoff clean.

---

Full write-up, the patch, and an idempotent preflight script that re-applies it after a plugin
update (the plugin lives in a cache directory, so updates wipe local fixes):
https://github.com/OWNER/claude-telegram-409-fix
