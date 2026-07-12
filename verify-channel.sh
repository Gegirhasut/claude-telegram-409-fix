#!/usr/bin/env bash
# Post-restart verification that the Telegram channel is genuinely healthy.
# Run this in a session started AFTER the patch was applied.
#
#   1. exactly ONE poller PROCESS          (two => stacked pollers, the 409 bug is live)
#   2. AT LEAST ONE socket to api.telegram.org  (zero => alive but deaf, however quiet it is)
#   3. ZERO "409 Conflict" lines over 90s
#
# Do NOT infer stacking from a socket count: bun's keep-alive pool holds several connections per
# process, and an earlier version of this script failed a healthy channel for having two. Stacking
# is counted in processes; sockets only tell you whether the one poller is attached to anything.
#
# Needs sudo for strace (ptrace_scope). Reads no secrets, prints no token.
set -uo pipefail

PID_FILE="$HOME/.claude/channels/telegram/bot.pid"
[ -f "$PID_FILE" ] || { echo "no bot.pid — the channel poller is not running"; exit 1; }
PID="$(cat "$PID_FILE")"

if ! ps -p "$PID" -o pid= >/dev/null 2>&1; then
  echo "bot.pid says $PID but that process is dead — restart Claude Code"; exit 1
fi

echo "poller pid $PID:"
ps -p "$PID" -o pid,ppid,etime,cmd | tail -1

BAD=0

# bot.pid only ever names the NEWEST poller: each start overwrites it. An orphan from a dead
# session -- whose parent claude is gone, so nothing reaps it -- stays invisible to a check that
# trusts the pid file. Enumerate every poller on the box instead.
echo
echo "== 0. orphaned pollers (bot.pid names only the newest) =="
ALL="$(pgrep -f 'bun server\.ts' | tr '\n' ' ')"
echo "   poller pids: ${ALL:-none}"
for p in $ALL; do
  [ "$p" = "$PID" ] && continue
  echo "   -> ORPHAN $p ($(ps -o etime= -p "$p" | tr -d ' ') old, $(ps -o pcpu= -p "$p" | tr -d ' ')% cpu) — a second poller on one token. BAD."
  BAD=1
done
[ "$BAD" -eq 0 ] && echo "   -> no orphans: OK"

echo
echo "== 1. poller PROCESSES (one token, one poller) =="
NPOLL="$(pgrep -f 'bun server\.ts' | wc -l | tr -d ' ')"
if [ "$NPOLL" -eq 1 ]; then
  echo "   -> 1 poller process: OK (no stacking)"
else
  echo "   -> $NPOLL poller processes: STACKED POLLERS — the 409 bug is live. BAD."
  BAD=1
fi

# Counting SOCKETS to infer stacking is wrong, and it cost an hour: bun's fetch keep-alive pool
# legitimately holds more than one connection per process, so ">1 socket" failed a HEALTHY channel.
# Stacking is a property of PROCESSES (check 1). What a socket count is actually good for is the
# opposite failure -- a poller that is ALIVE but attached to NOTHING. When the retry loop gave up
# (8x 409) it returned without exiting and MCP stdin kept the process alive: live pid, zero Telegram
# sockets, outbound tools fine, inbound stone deaf, and never another line of stderr. Silence is that
# bug's SIGNATURE, so check 3's "quiet == healthy" blesses it. Zero sockets = DEAF, full stop.
echo
echo "== 2. is the poller ATTACHED to Telegram? (zero sockets = deaf, however quiet) =="
TG_RE="$(getent ahostsv4 api.telegram.org 2>/dev/null | awk '{print $1}' | sort -u \
         | sed 's/\./\\./g' | paste -sd'|' -)"
[ -z "$TG_RE" ] && TG_RE='149\.154\.'
ss -tnp 2>/dev/null | grep "pid=$PID," | grep -E "$TG_RE" | awk '{print "   " $5}'
SOCKS="$(ss -tnp 2>/dev/null | grep "pid=$PID," | grep -cE "$TG_RE" || true)"
if [ "$SOCKS" -ge 1 ]; then
  echo "   -> $SOCKS connection(s) to api.telegram.org: OK (attached and polling)"
else
  echo "   -> ZERO connections to api.telegram.org: the poller is ALIVE but DEAF. BAD."
  echo "      The retry loop gave up and returned without exiting, or the token is held elsewhere."
  echo "      Check stderr for '409 Conflict persists'; a token held by another HOST will not show"
  echo "      up as a local orphan in check 0. curl getUpdates by hand: a 409 names the competitor."
  BAD=1
fi

echo
echo "== 3. 90s stderr watch (expect: one 'polling as', zero 409) =="
OUT="$(sudo timeout 90 strace -f -qq -s300 -e trace=write -p "$PID" 2>&1 \
        | grep -oE '"telegram channel[^"]*"' | sort | uniq -c)"
if [ -z "$OUT" ]; then
  echo "   (no channel stderr in 90s — quiet, which is what a healthy poller looks like)"
else
  echo "$OUT" | sed 's/^/   /'
fi

if printf '%s' "$OUT" | grep -q '409'; then
  echo
  echo "   -> 409 Conflict present: the channel is DEAF. Run preflight.sh and restart."
  exit 1
fi
echo "   -> zero 409: OK"

# An orphan whose parent died has no stdout/stderr left. The plugin's error handler writes the
# error to that dead pipe, which throws EPIPE, which it writes again -- a hot loop that pegs a
# core and makes the process deaf to SIGTERM (its shutdown handler writes to stderr first, so
# the handler itself dies). Only SIGKILL clears it.
if printf '%s' "$OUT" | grep -q 'EPIPE'; then
  echo "   -> EPIPE storm: this poller is orphaned and spinning. SIGTERM will NOT clear it; use kill -9. BAD."
  BAD=1
fi

echo
if [ "$BAD" -ne 0 ]; then
  echo "RESULT: the channel is NOT healthy — see the BAD lines above."
  exit 1
fi
echo "RESULT: healthy. Now send a DM to the bot and confirm it appears in the session."
