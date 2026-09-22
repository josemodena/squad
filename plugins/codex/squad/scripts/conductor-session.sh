#!/usr/bin/env bash
# Inspect, attach to, steer or interrupt the scheduler-owned App Server turn.
set -euo pipefail

SQUAD_TOOL=conductor-session.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings
squad_load_conductor_env
state="${SQUAD_CONDUCTOR_STATE:-$SQUAD_SCRATCH_ROOT/conductor-state}"
current="$state/current.json"
thread_state="$state/chief-of-staff-thread.json"
url="${SQUAD_CONDUCTOR_APP_SERVER_URL:-unix://$SQUAD_SCRATCH_ROOT/squad-app-server-gateway.sock}"
client="${SQUAD_CONDUCTOR_APP_SERVER_CLIENT:-${XDG_CONFIG_HOME:-$HOME/.config}/squad/bin/squad-conductor-appserver}"
command="${1:-inspect}"; shift || true

record="$thread_state"
[ -r "$record" ] || squad_die "There is no scheduler-owned thread to inspect."
thread="$(jq -r '.thread_id // empty' "$record")"
turn="$(jq -r '.turn_id // empty' "$record")"
attachable="$(jq -r '.attachable // false' "$record")"

resolved_args() {
  model="$(jq -r '.resolved.model // empty' "$record")"
  effort="$(jq -r '.resolved.reasoningEffort // empty' "$record")"
  approval="$(jq -r '.resolved.approvalPolicy // empty' "$record")"
  sandbox="$(jq -r '.resolved.sandbox.type // .resolved.sandbox // empty' "$record")"
  cwd="$(jq -r '.resolved.cwd // empty' "$record")"
  case "$sandbox" in workspaceWrite) sandbox=workspace-write ;; readOnly) sandbox=read-only ;; dangerFullAccess) sandbox=danger-full-access ;; esac
}

case "$command" in
  inspect)
    jq '{id,events,phase,thread_id,turn_id,turn_status,attachable,resolved}' "$record"
    if [ "$attachable" = true ]; then
      resolved_args
      printf 'Attach with the persisted policy: codex --remote %q%s%s%s%s%s resume %q\n' "$url" \
        "${model:+ --model $model}" "${effort:+ -c model_reasoning_effort=$effort}" \
        "" "" "${cwd:+ -C $cwd}" "$thread"
	  printf 'The gateway supplies and verifies the persisted sandbox=%s and approval=%s through App Server; Codex remote resume rejects permission flags.\n' "$sandbox" "$approval"
    else
      printf 'The thread has no rollout yet; wait until turn/start records attachable=true.\n'
    fi
    ;;
  attach)
    [ "$attachable" = true ] || squad_die "The thread is not attachable until its first turn has started."
    resolved_args
    args=(--remote "$url" --no-alt-screen)
    [ -z "$model" ] || args+=(--model "$model")
    [ -z "$effort" ] || args+=(-c "model_reasoning_effort=$effort")
    [ -z "$cwd" ] || args+=(-C "$cwd")
    [ -z "$cwd" ] || cd "$cwd"
    exec codex "${args[@]}" resume "$thread"
    ;;
  steer)
    [ -n "$thread" ] && [ -n "$turn" ] || squad_die "There is no named active turn to steer."
    [ "$#" -gt 0 ] || squad_die "steer requires text"
    exec "$client" steer --url "$url" --thread "$thread" --turn "$turn" --input "$*"
    ;;
  interrupt)
    [ -n "$thread" ] && [ -n "$turn" ] || squad_die "There is no named active turn to interrupt."
    exec "$client" interrupt --url "$url" --thread "$thread" --turn "$turn"
    ;;
  rollover)
    [ ! -e "$current" ] || squad_die "Cannot roll over while a scheduler turn is active."
    exec "$client" rollover --url "$url" --thread "$thread"
    ;;
  *) squad_die "Usage: conductor-session.sh inspect|attach|steer <text>|interrupt|rollover" ;;
esac
