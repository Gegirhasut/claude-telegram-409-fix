#!/usr/bin/env bash
# Ensure the installed Claude Code Telegram plugin still carries the 409 self-conflict fix.
#
# The plugin retries bot.start() without bot.stop(), stacking a second getUpdates long-poll
# on one bot token. The two race, Telegram 409s one, and the survivor acks updates whose
# handlers never run -- the channel goes silently deaf after a session restart. See README.md.
#
# The plugin lives in a CACHE dir, so an update wipes the patch. This re-applies it.
# Idempotent: safe to run on every launch. No-ops when the fix is already present, and no-ops
# when upstream has fixed it -- detected by inspecting the code, NOT by trusting the version.
#
# Exit: 0 = fine (patched / upstream-fixed / plugin absent)
#       1 = fix is MISSING and could not be applied automatically
set -uo pipefail

FIX_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_ROOT="${HOME}/.claude/plugins/cache/claude-plugins-official/telegram"
PATCH="$FIX_DIR/fix.diff"

# Fixed: the retry path tears the old polling loop down before restarting it. Matches both
# shapes -- this repo's patch (`bot.stop().catch`) and the form proposed upstream, which wraps
# it in the plugin's own house idiom (`Promise.resolve(bot.stop()).catch`). Either one means
# the poller is stopped before a retry, so there is nothing to do.
FIXED_MARKER='bot\.stop\(\)\)?\.catch'
# Buggy: onStart zeroes the retry counter before the 409 throws => backoff 0, bailout unreachable.
BUG_MARKER='attempt = 0'

red()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
ok()   { [ -n "${TG_FIX_QUIET:-}" ] || printf '\033[0;32m%s\033[0m\n' "$*" >&2; }

[ -d "$PLUGIN_ROOT" ] || { ok "telegram-fix: plugin not installed - nothing to do"; exit 0; }

VERSION="$(ls -1 "$PLUGIN_ROOT" 2>/dev/null | sort -V | tail -1)"
[ -n "$VERSION" ] || { ok "telegram-fix: no plugin version found - nothing to do"; exit 0; }

SERVER="$PLUGIN_ROOT/$VERSION/server.ts"
[ -f "$SERVER" ] || { ok "telegram-fix: $VERSION has no server.ts - nothing to do"; exit 0; }

has_fix=0; grep -qE "$FIXED_MARKER" "$SERVER" && has_fix=1
has_bug=0; grep -qF "$BUG_MARKER"   "$SERVER" && has_bug=1

# Already safe: the retry stops the bot, and the backoff counter is not zeroed.
if [ "$has_fix" -eq 1 ] && [ "$has_bug" -eq 0 ]; then
  ok "telegram-fix: plugin $VERSION carries the 409 fix - ok"
  exit 0
fi

# Ambiguous: stops the bot, but still zeroes the counter somewhere. Do not overwrite.
if [ "$has_fix" -eq 1 ] && [ "$has_bug" -eq 1 ]; then
  warn "telegram-fix: plugin $VERSION stops the bot on retry but still contains '$BUG_MARKER'."
  warn "telegram-fix: looks partially fixed upstream - NOT patching. Review by hand:"
  warn "              \$HOME/.claude/plugins/cache/claude-plugins-official/telegram/$VERSION/server.ts"
  exit 0
fi

red ""
red "  ############################################################"
red "  #  TELEGRAM 409 FIX IS MISSING from plugin $VERSION"
red "  #  The channel will connect, list its tools, and be DEAF."
red "  #  Incoming messages are consumed and silently discarded."
red "  ############################################################"
red ""

if [ ! -f "$PATCH" ]; then
  red "  -> fix.diff not found next to this script; cannot auto-apply."
  exit 1
fi

# Never leave a half-applied file behind: dry-run first, and back up before writing.
if patch --dry-run -s -p1 -f "$SERVER" < "$PATCH" >/dev/null 2>&1; then
  cp -a "$SERVER" "$SERVER.prepatch-$(date +%Y%m%d%H%M%S)"
  patch -s -p1 -f "$SERVER" < "$PATCH"
  red "  -> patch applied to $VERSION (previous file kept as server.ts.prepatch-*)"
  red "  -> RESTART Claude Code for it to take effect"
  exit 0
fi

red "  -> Could NOT auto-apply: plugin $VERSION differs from the 0.0.6 the patch was cut from."
red "  -> Check whether upstream fixed it; if not, re-cut the patch by hand. See README.md."
exit 1
