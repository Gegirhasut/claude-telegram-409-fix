# claude-telegram-409-fix

A fix for a silent, deterministic bug in the official Claude Code **Telegram channel plugin**
(`claude-plugins-official/telegram`, version **0.0.6**): after a session restart, the channel
reports itself connected and healthy, and is **permanently deaf to incoming messages**.

Incoming DMs are not queued or delayed. They are consumed and thrown away.

## Symptom

- The channel shows **connected · 4 tools**.
- **Outbound works.** Sending a reply succeeds and returns a `message_id`.
- **Inbound is dead.** Messages show "delivered" in the Telegram app and never reach any session.
- `getWebhookInfo` reports `pending_update_count: 0`.
- Nothing appears in the UI, the `/mcp` panel, or any log file.

The zero pending count is the trap. It reads as "nothing is stuck", so it looks like proof that the
bot is idle and fine. It is the opposite: it means **something is draining the update queue**. The
messages are being fetched and discarded before any handler runs.

You can see the loss in Telegram's own message ids. They are per-chat and sequential, so if the last
message a session received was id *N*, and the next reply the bot sends is assigned id *N+11*, then
ten messages existed in that chat and reached nobody.

## Reproducing it

1. Run a Claude Code session with the Telegram channel (long polling — no webhook).
2. Restart Claude Code. The new `server.ts` terminates the previous poller and **immediately** starts
   polling, while Telegram still holds the previous `getUpdates` long-poll open for ~30–50s.
3. The new poller takes a `409 Conflict`.
4. From that moment the channel never receives another message for the life of the session.

It reproduces every time. It is not a flake.

The only evidence is written to stderr — a pipe nothing reads:

```
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s
telegram channel: polling as @<bot>
telegram channel: 409 Conflict, retrying in 0s      # forever, ~9 per 30 seconds
```

## Root cause: the poller races itself

There is **no competing consumer**. The process fights its own previous polling loop over the single
bot token. Two bugs in the retry loop (`server.ts`, lines 999–1036) compound:

**1. `bot.start()` is retried without `bot.stop()`.**
grammY leaves its polling loop running when `start()` rejects. The retry stacks a *second*
long-poll on the same token. Telegram permits exactly one `getUpdates` consumer, so it `409`s one of
them — and **the survivor acks updates whose handlers never run**. That is where the messages go.
At the socket level the single plugin process holds **two** connections to `api.telegram.org`, both
actively transferring.

**2. `onStart` resets `attempt = 0` (server.ts:1004) *before* the 409 throws.**
The backoff is `Math.min(1000 * attempt, 15000)`, so it evaluates to **0 ms** — a hot retry loop with
no delay. It also makes the "409 persists after 8 attempts — Exiting" bailout at **server.ts:1023**
permanently unreachable, because `attempt` is zeroed again on every restart before the next throw.

Once entered, the state never recovers.

### How to prove there is no external competitor

Freeze the poller (`SIGSTOP` — reversible, not a kill), wait for Telegram's in-flight long-poll to
expire, then ask Telegram once whether anyone else holds the token. Passing no `offset` acks nothing,
so this drops no messages:

```bash
kill -STOP "$(cat ~/.claude/channels/telegram/bot.pid)"
sleep 60
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?timeout=0"
#  => 200 {"ok":true,"result":[]}    no 409 -- but this does NOT prove nothing else is polling
kill -CONT "$(cat ~/.claude/channels/telegram/bot.pid)"
```

A clean result here is **not** proof that no competitor exists. `bot.pid` names only the newest
poller, so an orphaned one keeps polling right through the probe; and a remote or intermittent
consumer can simply be idle at the instant you sample. `pending_update_count` is 0 either way.

There is also no Bot API call that evicts another `getUpdates` consumer — if the holder is not a
process you can reach, revoking the token in BotFather is the only way to break its grip.

## The fix

See [`fix.diff`](fix.diff):

- `await bot.stop().catch(() => {})` before every retry — tears down the old polling loop, so nothing
  stacks and nothing races.
- Backoff floors at 1s, and `attempt` resets only after a run that actually polled for >30s — so the
  8-attempt bailout is reachable and a *genuine* conflict now fails **loudly** instead of spinning
  forever.

### Applying it

The plugin lives in a **cache directory**, so a plugin update overwrites it and the bug comes back:

```
~/.claude/plugins/cache/claude-plugins-official/telegram/<version>/server.ts
```

`preflight.sh` checks whether the installed plugin still carries the fix, warns loudly if not, and
re-applies it. It is idempotent, and it no-ops if the fix (or an upstream equivalent) is already
present — it verifies by inspecting the code, not by trusting the version number.

```bash
./preflight.sh                 # check, and re-apply if missing
./verify-channel.sh            # after restarting: exactly 1 connection, zero 409s in 90s
```

To make it automatic, launch Claude Code through the wrapper, which runs the preflight first:

```bash
ln -sf "$PWD/claude-wrapper.sh" ~/.local/bin/claude
# or:  alias claude="$PWD/claude-wrapper.sh"
```

Restart Claude Code for a patched `server.ts` to take effect — the plugin process is a child of the
session.

## Upstream

[`ISSUE.md`](ISSUE.md) is a ready-to-file bug report.

Beyond the patch, this failure is invisible by construction: the sole signal is a `stderr` write to a
pipe nothing reads, while the channel keeps advertising itself as connected. A repeated 409 — or any
state where the poller is not actually consuming updates — should surface in the `/mcp` panel and
degrade the channel's reported status.

## License

MIT — see [LICENSE](LICENSE). This covers the scripts and documentation in this repository. The
patch in `fix.diff` is a modification to the upstream plugin, which carries its own license; no
upstream source is redistributed here.
