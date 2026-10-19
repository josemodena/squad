#!/usr/bin/env bash
# PreCompact: write the hand-over before the context is compacted, so the state
# of the work survives in the one place the next session already looks.
#
# It posts on the sprint issue when it can. When it cannot, it prints the
# hand-over instead, so the text is at least in the transcript. It never fails
# by itself; hooks.json sets onFailure "block", so if it cannot start or times
# out, the compaction is blocked rather than run without a hand-over.
set -uo pipefail

# Read the hook's input first, on every path. Since Claude Code 2.1.299 an
# action the harness cannot hand to a hook is refused, not let through.
[ -t 0 ] || timeout 5 cat >/dev/null 2>&1 || true

# A meeting neither renames the Administrator tab nor posts its handover/commits its files.
if [ -n "${SQUAD_MEETING_ID:-}" ]; then
  printf 'Squad meeting: preserve decisions and open questions in a meeting checkpoint.\n'
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HANDOVER="$PLUGIN_ROOT/scripts/handover.sh"

if [ ! -x "$HANDOVER" ]; then
  printf 'Squad: the hand-over script is missing, so nothing was written.\n'
  exit 0
fi

# The hand-over reads the board's in-flight lines and the last hand-over, so
# it gets 40 of the hook's 60 seconds; the fallback below reads nothing.
if out="$(timeout 40 bash "$HANDOVER" 2>&1)"; then
  printf 'Squad: hand-over posted on the sprint issue.\n%s\n' "$out"
  exit 0
fi

case "$out" in
  *"No Squad settings found"*) exit 0 ;;
esac

printf 'Squad: the hand-over could not be posted (%s). It reads:\n\n' "$(printf '%s' "$out" | head -1)"
not_read="Not read: the hand-over could not be posted; see the newest hand-over on the sprint issue."
timeout 15 bash "$HANDOVER" --dry-run --in-flight "$not_read" --next "$not_read" --waits "$not_read" 2>/dev/null || true
exit 0
