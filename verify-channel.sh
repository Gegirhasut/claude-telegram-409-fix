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

echo
echo "== 1. connections to the Telegram Bot API =="
CONNS="$(ss -tnp 2>/dev/null | grep -c "pid=$PID," || true)"
ss -tnp 2>/dev/null | grep "pid=$PID," | awk '{print "   " $5}'
if [ "$CONNS" -eq 1 ]; then
  echo "   -> 1 connection: OK (no stacked poller)"
elif [ "$CONNS" -eq 0 ]; then
  echo "   -> 0 connections: the poller is NOT polling. BAD."
else
  echo "   -> $CONNS connections: STACKED POLLERS — the 409 bug is live. BAD."
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
echo
echo "   -> zero 409: OK"
echo
echo "Now send a DM to the bot and confirm it appears in the session."
