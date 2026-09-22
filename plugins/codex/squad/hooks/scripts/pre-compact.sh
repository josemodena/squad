#!/usr/bin/env bash
# PreCompact: write the hand-over before the context is compacted, so the state
# of the work survives in the one place the next session already looks.
#
# It carries the three human-maintained sections forward from the latest
# handover. Compaction must not replace useful state with empty defaults.
set -uo pipefail

# A meeting neither renames the Administrator tab nor posts its handover/commits its files.
if [ -n "${SQUAD_MEETING_ID:-}" ]; then
  printf 'Squad meeting: preserve decisions and open questions in a meeting checkpoint.\n'
  exit 0
fi

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HANDOVER="$PLUGIN_ROOT/scripts/handover.sh"

if [ ! -x "$HANDOVER" ]; then
  printf 'Squad: the hand-over script is missing, so nothing was written.\n'
  exit 0
fi

latest="$(bash "$HANDOVER" --latest 2>/dev/null || true)"
section() {
  local heading="$1"
  printf '%s\n' "$latest" | awk -v heading="$heading" '
    $0 == "## " heading {inside=1; next}
    inside && /^## / {exit}
    inside {lines[++n]=$0}
    END {
      first=1; while (first<=n && lines[first]=="") first++
      last=n; while (last>=first && lines[last]=="") last--
      for (i=first; i<=last; i++) print lines[i]
    }'
}

args=()
if [ -n "$latest" ]; then
  in_flight="$(section 'Agents in flight')"
  next_actions="$(section 'Next actions in order')"
  waits="$(section 'Waits')"
  [ -z "$in_flight" ] || args+=(--in-flight "$in_flight")
  [ -z "$next_actions" ] || args+=(--next "$next_actions")
  [ -z "$waits" ] || args+=(--waits "$waits")
fi

if out="$(bash "$HANDOVER" "${args[@]}" 2>&1)"; then
  printf 'Squad: hand-over posted on the sprint issue.\n%s\n' "$out"
  exit 0
fi

case "$out" in
  *"No Squad settings found"*) exit 0 ;;
esac

printf 'Squad: the hand-over could not be posted: %s\n' "$(printf '%s' "$out" | head -1)"
exit 0
