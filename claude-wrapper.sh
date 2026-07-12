#!/usr/bin/env bash
# Launch Claude Code, but first make sure the Telegram plugin still carries the
# 409 self-conflict fix (a plugin update silently wipes it — the cache dir is
# overwritten, and the resulting failure is a channel that looks connected and
# is deaf). See preflight.sh / README.md.
#
# Install:
#   ln -sf /path/to/claude-telegram-409-fix/claude-wrapper.sh ~/.local/bin/claude
# or, if you prefer to keep `claude` pointing at the real binary:
#   alias claude='/path/to/claude-telegram-409-fix/claude-wrapper.sh'
set -uo pipefail

FIX_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Resolve the real claude, skipping this wrapper if it shadows it on PATH.
REAL_CLAUDE=""
self="$(readlink -f "${BASH_SOURCE[0]}")"
while IFS= read -r c; do
  [ "$(readlink -f "$c")" = "$self" ] && continue
  REAL_CLAUDE="$c"; break
done < <(which -a claude 2>/dev/null)

if [ -z "$REAL_CLAUDE" ]; then
  printf '\033[1;31mclaude-wrapper: cannot find the real `claude` on PATH\033[0m\n' >&2
  exit 127
fi

# Advisory: never block the launch on a preflight failure — a broken channel is
# worse than annoying, but an un-launchable claude is worse still.
#
# TG_FIX_QUIET silences the "all good" line: on a normal launch this must be
# invisible. A wiped patch still prints loudly (warn/red ignore TG_FIX_QUIET),
# which is the only case worth interrupting for. Unset it to confirm it ran.
TG_FIX_QUIET=1 "$FIX_DIR/preflight.sh" || true

exec "$REAL_CLAUDE" "$@"
