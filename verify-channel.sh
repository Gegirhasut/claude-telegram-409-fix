#!/usr/bin/env bash
# Post-restart verification that the Telegram channel is genuinely healthy.
# Run this in a session started AFTER the patch was applied.
#
#   1. exactly ONE connection to api.telegram.org  (two => the stacking bug is live)
#   2. ZERO "409 Conflict" lines over 90s
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
echo "== 1. connections to the Telegram Bot API =="
CONNS="$(ss -tnp 2>/dev/null | grep -c "pid=$PID," || true)"
ss -tnp 2>/dev/null | grep "pid=$PID," | awk '{print "   " $5}'
if [ "$CONNS" -eq 1 ]; then
  echo "   -> 1 connection: OK (no stacked poller)"
elif [ "$CONNS" -eq 0 ]; then
  echo "   -> 0 connections: the poller is NOT polling. BAD."
  BAD=1
else
  echo "   -> $CONNS connections: STACKED POLLERS — the 409 bug is live. BAD."
  BAD=1
fi

echo
echo "== 2. 90s stderr watch (expect: one 'polling as', zero 409) =="
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
