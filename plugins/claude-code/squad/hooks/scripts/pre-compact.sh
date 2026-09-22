#!/usr/bin/env bash
# PreCompact: write the hand-over before the context is compacted, so the state
# of the work survives in the one place the next session already looks.
#
# It posts on the sprint issue when it can. When it cannot, it prints the
# hand-over instead, so the text is at least in the transcript. It never fails.
set -uo pipefail

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

if out="$(bash "$HANDOVER" 2>&1)"; then
  printf 'Squad: hand-over posted on the sprint issue.\n%s\n' "$out"
  exit 0
fi

case "$out" in
  *"No Squad settings found"*) exit 0 ;;
esac

printf 'Squad: the hand-over could not be posted (%s). It reads:\n\n' "$(printf '%s' "$out" | head -1)"
bash "$HANDOVER" --dry-run 2>/dev/null || true
exit 0
