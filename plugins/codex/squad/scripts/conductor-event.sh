#!/usr/bin/env bash
# Add one durable, identified wake event to the conductor's input spool.
set -euo pipefail

SQUAD_TOOL="conductor-event.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings
squad_load_conductor_env

usage() {
  printf '%s\n' 'Usage: conductor-event.sh --id <stable-id> --kind <job|review|dependency|quota|handover> --reason <text> [--ready-at <epoch>]' >&2
  exit 1
}

event_id="" kind="" reason="" ready_at=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) event_id="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    --ready-at) ready_at="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$event_id" ] && [ -n "$kind" ] && [ -n "$reason" ] || usage
case "$event_id" in *[!A-Za-z0-9._:-]*|'') squad_die "event id contains an unsafe character: $event_id" ;; esac
case "$kind" in job|review|dependency|quota|handover) ;; *) squad_die "unsupported event kind: $kind" ;; esac
case "$ready_at" in ''|*[!0-9]*) [ -z "$ready_at" ] || squad_die "ready-at must be epoch seconds" ;; esac
: "${ready_at:=$(date -u +%s)}"

state="${SQUAD_CONDUCTOR_STATE:-$SQUAD_SCRATCH_ROOT/conductor-state}"
mkdir -p "$state/inbox"
key="$(printf '%s' "$event_id" | sha256sum | awk '{print $1}')"
target="$state/inbox/$key.json"
[ ! -e "$target" ] || exit 0
tmp="$state/inbox/.${key}.$$"
jq -cn --arg id "$event_id" --arg kind "$kind" --arg reason "$reason" \
  --argjson ready_at "$ready_at" '{id:$id,kind:$kind,reason:$reason,ready_at:$ready_at}' >"$tmp"
if ln "$tmp" "$target" 2>/dev/null; then
  printf 'queued %s\n' "$event_id"
fi
rm -f "$tmp"
