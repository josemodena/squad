#!/usr/bin/env bash
# Claim newly actionable events and start at most one owned Administrator session.
set -uo pipefail

SQUAD_TOOL="conductor.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/settings.sh"
usage() { printf '%s\n' 'Usage: conductor.sh [--issue <number>] [--dry-run]' >&2; exit 1; }
issue_number="" dry_run=0 ack_id="" ack_status=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue) issue_number="${2:-}"; [ -n "$issue_number" ] || usage; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --ack) ack_id="${2:-}"; ack_status="${3:-}"; shift 3 ;;
    *) usage ;;
  esac
done

squad_load_settings
squad_load_conductor_env
SESSION="$SQUAD_CONDUCTOR_SESSION" TAB="$SQUAD_CONDUCTOR_TAB" HARNESS="$SQUAD_CONDUCTOR_COMMAND"
ROOT="$SQUAD_SCRATCH_ROOT" STATE="${SQUAD_CONDUCTOR_STATE:-$SQUAD_SCRATCH_ROOT/conductor-state}"
LOG="${SQUAD_CONDUCTOR_LOG:-$ROOT/conductor.log}"
LEDGER="${SQUAD_CONDUCTOR_LEDGER:-$ROOT/conductor-ledger.jsonl}"
HOLD="${SQUAD_CONDUCTOR_HOLD:-$ROOT/conductor.hold}"
MAX_ATTEMPTS="${SQUAD_CONDUCTOR_MAX_ATTEMPTS:-3}" RETRY_DELAY="${SQUAD_CONDUCTOR_RETRY_SECONDS:-300}"
LAUNCH_GRACE="${SQUAD_CONDUCTOR_LAUNCH_GRACE_SECONDS:-30}"
now() { printf '%s\n' "${SQUAD_CONDUCTOR_NOW:-$(date -u +%s)}"; }
mkdir -p "$STATE"/{inbox,pending,claimed,consumed,stopped,results,acks,progress,controllers}
log() { printf '%s  %-9s %s\n' "$(date -u -d "@$(now)" '+%Y-%m-%d %H:%M:%S UTC')" "$1" "$2" >>"$LOG"; }
skip() { log skip "$1"; exit 0; }
atomic_json() { local target="$1"; shift; local tmp="${target}.$$"; jq -cn "$@" >"$tmp" && mv -f "$tmp" "$target"; }
event_key() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
event_known() { local key="$1" d; for d in inbox pending claimed consumed stopped; do [ ! -e "$STATE/$d/$key.json" ] || return 0; done; return 1; }
ledger() { local type="$1"; shift; jq -cn --arg type "$type" --argjson at "$(now)" "$@" '{at:$at,type:$type} + $ARGS.named' >>"$LEDGER"; }

# A completion writes its own atomic inbox record before contending with the
# scheduler lock. A timer tick can delay reconciliation, but cannot lose it.
if [ -n "$ack_id" ]; then
  case "$ack_status" in ''|*[!0-9]*) squad_die "ack status must be numeric" ;; esac
  atomic_json "$STATE/acks/$ack_id.json" --arg id "$ack_id" --argjson status "$ack_status" \
    --argjson finished_at "$(now)" '{id:$id,status:$status,finished_at:$finished_at}'
  exit 0
fi

exec 9>"$STATE/lock"
if command -v flock >/dev/null 2>&1; then flock -n 9 || skip "lock held: another conductor run is in progress"; fi
quota_line() {
  local bin out
  if [ -n "${SQUAD_CONDUCTOR_QUOTA:-}" ]; then printf '%s\n' "$SQUAD_CONDUCTOR_QUOTA"; return; fi
  bin="$(command -v "$SQUAD_QUOTA_COMMAND" 2>/dev/null || true)"
  [ -n "$bin" ] || [ ! -x "$SCRIPT_DIR/$SQUAD_QUOTA_COMMAND" ] || bin="$SCRIPT_DIR/$SQUAD_QUOTA_COMMAND"
  [ -n "$bin" ] || { printf 'unreadable\n'; return; }
  out="$("$bin" 2>&1 || true)"; printf '%s\n' "$out" | head -1
}

# Reconcile durable completion inbox records under the scheduler lock.
for ack in "$STATE"/acks/*.json; do
  [ -e "$ack" ] || continue
  ack_name="$(basename "$ack" .json)"
  [ "$(jq -r '.id // empty' "$STATE/current.json" 2>/dev/null || true)" = "$ack_name" ] || continue
  finish_usage="$(quota_line | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  jq --arg usage "$finish_usage" '. + {usage_finish:$usage}' "$ack" >"$STATE/results/$ack_name.json.tmp" \
    && mv -f "$STATE/results/$ack_name.json.tmp" "$STATE/results/$ack_name.json"
  ledger finish --arg launch_id "$ack_name" --arg result "$(jq -r .status "$ack")" --arg usage "$finish_usage" --arg attribution shared-or-unknown
  rm -f "$ack"
done

# Releases before the claim journal could leave claimed files without a
# current transaction. Returning them to pending is safe: their attempts and
# stable identities are preserved.
if [ ! -e "$STATE/current.json" ]; then
  for orphan in "$STATE"/claimed/*.json; do
    [ -e "$orphan" ] || continue
    mv -f "$orphan" "$STATE/pending/$(basename "$orphan")"
    ledger recovered --arg event_id "$(jq -r .id "$STATE/pending/$(basename "$orphan")")" --arg boundary orphan-claim
  done
fi

valid_id() { case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; *) return 0 ;; esac; }
field() { printf '%s' "$1" | sed -n "s/.*$2:[[:space:]]*\([^|]*\).*/\1/p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
placeholder() { printf '%s' "$1" | grep -Eiq '(<[^>]+>|(TODO|TBD|placeholder))'; }
ready_ids="$STATE/.ready-ids.$$"; : >"$ready_ids"
trap 'rm -f "$ready_ids"' EXIT
queue_event() {
  local id="$1" kind="$2" reason="$3" ready_at="$4" source="$5" key first
  valid_id "$id" || skip "malformed event id: $id"
  placeholder "$id $reason" && skip "event '$id' contains a placeholder"
  key="$(event_key "$id")"; printf '%s\n' "$id" >>"$ready_ids"
  event_known "$key" && return 0
  first="$(now)"
  atomic_json "$STATE/pending/$key.json" --arg id "$id" --arg kind "$kind" --arg reason "$reason" \
    --arg source "$source" --argjson ready_at "$ready_at" --argjson first_seen "$first" \
    '{id:$id,kind:$kind,reason:$reason,source:$source,ready_at:$ready_at,first_seen:$first_seen,attempts:0}'
  ledger observed --arg event_id "$id" --arg kind "$kind" --arg reason "$reason"
}

worker_terminal_event() {
  local id="$1" path="$2" rollout="$3" thread="$4" turn="$5"
  local records session_ids session_identity_valid matches terminal error_shape error_message error_code reason event_id terminal_line
  [ -r "$rollout" ] || { log skip "worker '$id' rollout is unreadable: $rollout"; return 1; }
  records="$(jq -sc '.' "$rollout" 2>/dev/null)" || { log skip "worker '$id' rollout is not valid JSONL: $rollout"; return 1; }
  session_identity_valid="$(printf '%s' "$records" | jq -r \
    '[.[] | select(.type == "session_meta") | .payload.id] | length > 0 and all(.[]; type == "string" and test("\\S"))')"
  if [ "$session_identity_valid" != true ]; then
    log skip "worker '$id' rollout has invalid session identity: $rollout"
    return 1
  fi
  session_ids="$(printf '%s' "$records" | jq -c '[.[] | select(.type == "session_meta") | .payload.id] | unique')"
  if [ "$(printf '%s' "$session_ids" | jq 'length')" -ne 1 ]; then
    log skip "worker '$id' rollout has ambiguous session identity: $rollout"
    return 1
  fi
  if [ -n "$thread" ] && [ "$(printf '%s' "$session_ids" | jq -r '.[0]')" != "$thread" ]; then
    log skip "worker '$id' thread '$thread' does not match rollout $rollout"
    return 1
  fi
  matches="$(printf '%s' "$records" | jq -c --arg turn "$turn" \
    '[.[] | select(.type == "event_msg" and .payload.type == "task_complete" and .payload.turn_id == $turn)]')"
  [ "$(printf '%s' "$matches" | jq 'length')" -eq 1 ] || return 1
  terminal="$(printf '%s' "$matches" | jq -c '.[0].payload')"
  error_shape="$(printf '%s' "$terminal" | jq -r 'if .error == null then "success" elif (.error | type) == "object" then "failure" else "invalid" end')"
  if [ "$error_shape" = invalid ]; then
    log skip "worker '$id' rollout has unsupported task_complete error shape: $rollout"
    return 1
  fi
  error_message="$(printf '%s' "$terminal" | jq -r '(.error.message | if . == null then empty elif type == "string" then . else tojson end)')"
  error_code="$(printf '%s' "$terminal" | jq -r '(.error.codex_error_info | if . == null then empty elif type == "string" then . else tojson end)')"
  if [ "$error_shape" = failure ]; then
    event_id="${id}.worker-failed"
    reason="worker turn $turn failed${error_code:+ ($error_code)}${error_message:+: $error_message}"
    terminal_line="FAILED: $reason"
  else
    event_id="${id}.worker-completed"
    reason="worker turn $turn completed without marker; reconcile its output before deciding whether to relaunch"
    terminal_line="COMPLETED: $reason"
  fi
  if [ -w "$path" ] && [ "$(tail -1 "$path" 2>/dev/null)" = RUNNING ]; then
    printf '%s\n' "$terminal_line" >>"$path"
  fi
  queue_event "$event_id" job "$reason" "$(now)" worker-lifecycle
}

# Observe replies without spending model capacity or changing board state.
# Errors persist a bounded backoff; normal recovery must still process other work.
if [ "$SQUAD_CONTINUATION_MODE" = native ]; then
  bash "$SCRIPT_DIR/runtime.sh" inbox poll >/dev/null 2>&1 || true
fi

# Native mode recovers from durable execution, not human-authored handover syntax.
# Native notifications remain the normal path while the Administrator is active.
if [ "$SQUAD_CONTINUATION_MODE" = native ] && [ ! -e "$HOLD" ] && [ ! -e "$STATE/current.json" ]; then
  recovery="$(bash "$SCRIPT_DIR/runtime.sh" wake 2>>"$LOG")" || skip "runtime recovery unreadable"
  if [ "$(printf '%s' "$recovery" | jq -r '.ready')" = true ]; then
    bash "$SCRIPT_DIR/conductor-event.sh" --id "$(printf '%s' "$recovery" | jq -r '.id')" \
      --kind handover --reason "$(printf '%s' "$recovery" | jq -r '.reason')" >>"$LOG" 2>&1 || skip "could not record recovery event"
  fi
fi

# Import externally observed review, dependency, job or quota events.
for f in "$STATE"/inbox/*.json; do
  [ -e "$f" ] || continue
  id="$(jq -r '.id // empty' "$f")"; kind="$(jq -r '.kind // empty' "$f")"
  reason="$(jq -r '.reason // empty' "$f")"; ready_at="$(jq -r '.ready_at // 0' "$f")"
  key="$(event_key "$id")"
  if [ ! -e "$STATE/pending/$key.json" ] && [ ! -e "$STATE/claimed/$key.json" ] \
     && [ ! -e "$STATE/consumed/$key.json" ] && [ ! -e "$STATE/stopped/$key.json" ]; then
    first="$(now)"
    atomic_json "$STATE/pending/$key.json" --arg id "$id" --arg kind "$kind" --arg reason "$reason" \
      --arg source external --argjson ready_at "$ready_at" --argjson first_seen "$first" \
      '{id:$id,kind:$kind,reason:$reason,source:$source,ready_at:$ready_at,first_seen:$first_seen,attempts:0}'
    ledger observed --arg event_id "$id" --arg kind "$kind" --arg reason "$reason"
  fi
  rm -f "$f"
done

# Validate and derive events from the continuation contract. Prose alone cannot wake.
if [ "$SQUAD_CONTINUATION_MODE" != native ]; then
if [ -z "$issue_number" ]; then issue_number="$(bash "$SCRIPT_DIR/squad.sh" sprint-issue 2>/dev/null || true)"; fi
handover="${SQUAD_CONDUCTOR_HANDOVER:-}"
if [ -z "$handover" ] && [ -n "$issue_number" ]; then handover="$(bash "$SCRIPT_DIR/handover.sh" --latest --issue "$issue_number" 2>/dev/null || true)"; fi
if [ -n "$handover" ]; then
  [ "$(printf '%s\n' "$handover" | head -1)" = "$SQUAD_HANDOVER_MARKER" ] || skip "malformed hand-over marker"
  next_actions="$(printf '%s\n' "$handover" | squad_handover_section "$SQUAD_HANDOVER_NEXT_HEADING")"
  in_flight="$(printf '%s\n' "$handover" | squad_handover_section "$SQUAD_HANDOVER_IN_FLIGHT_HEADING")"
  waits="$(printf '%s\n' "$handover" | squad_handover_section "$SQUAD_HANDOVER_WAITS_HEADING")"
  events="$(printf '%s\n' "$handover" | squad_handover_section "$SQUAD_HANDOVER_EVENTS_HEADING")"
  [ -n "$next_actions" ] || skip "hand-over has an empty '$SQUAD_HANDOVER_NEXT_HEADING' section"
  if ! printf '%s\n' "$handover" | grep -qxF "## $SQUAD_HANDOVER_EVENTS_HEADING"; then
    skip "hand-over predates the event contract; write a new five-section hand-over with stable event ids"
  fi
  if [ -n "$in_flight" ] && [ "$in_flight" != "$SQUAD_HANDOVER_IN_FLIGHT_DEFAULT" ]; then
    while IFS= read -r line; do
      id="$(field "$line" id)"; path="$(field "$line" log)"; marker="$(field "$line" marker)"
      rollout="$(field "$line" rollout)"; thread="$(field "$line" thread)"; turn="$(field "$line" turn)"
      valid_id "$id" && [ -n "$path" ] && [ -n "$marker" ] || skip "in-flight work is malformed; require id, log and marker"
      placeholder "$line" && skip "in-flight event '$id' contains a placeholder"
      case "$marker" in *[!A-Za-z0-9._:-]*|'') skip "marker for '$id' is malformed" ;; esac
      if [ -r "$path" ] && [ "$(tail -1 "$path" 2>/dev/null)" = "$marker" ]; then
        queue_event "$id" job "background job reached $marker" "$(now)" handover
        continue
      fi
      if [ -n "$rollout$thread$turn" ]; then
        [ -n "$rollout" ] && [ -n "$turn" ] || skip "in-flight worker '$id' lifecycle identity is incomplete; require rollout and turn"
        worker_terminal_event "$id" "$path" "$rollout" "$thread" "$turn" || true
      fi
    done <<EOF
$in_flight
EOF
  fi
  if [ -n "$waits" ] && [ "$waits" != "$SQUAD_HANDOVER_WAITS_DEFAULT" ]; then
    while IFS= read -r line; do
      id="$(field "$line" id)"; until="$(field "$line" until)"; reason="$(field "$line" reason)"; ready="$(field "$line" ready)"
      valid_id "$id" && [ -n "$until" ] || skip "wait is malformed; require id and until"
      placeholder "$line" && skip "wait event '$id' contains a placeholder"
      until_ts="$(date -u -d "$until" +%s 2>/dev/null || true)"; [ -n "$until_ts" ] || skip "wait time for '$id' could not be parsed: $until"
      [ "$(now)" -ge "$until_ts" ] || continue
      [ "$ready" = true ] || { log skip "elapsed wait '$id' has no explicitly agreed ready work"; continue; }
      queue_event "$id" quota "${reason:-timed wait elapsed}" "$until_ts" handover
    done <<EOF
$waits
EOF
  fi
  if [ -n "$events" ] && [ "$events" != "$SQUAD_HANDOVER_EVENTS_DEFAULT" ]; then
    while IFS= read -r line; do
      id="$(field "$line" id)"; kind="$(field "$line" kind)"; reason="$(field "$line" reason)"
      valid_id "$id" && [ -n "$kind" ] && [ -n "$reason" ] || skip "wake event is malformed; require id, kind and reason"
      case "$kind" in job|review|dependency|quota|handover) ;; *) skip "wake event '$id' has unsupported kind '$kind'" ;; esac
      queue_event "$id" "$kind" "$reason" "$(now)" handover
    done <<EOF
$events
EOF
  fi
fi

fi # legacy handover compatibility

# Complete a journaled multi-event claim after any interruption. A release from
# the previous implementation with no journal was recovered above.
if [ -e "$STATE/current.json" ] && [ "$(jq -r '.phase' "$STATE/current.json")" = claiming ]; then
  while IFS= read -r key; do
    [ ! -e "$STATE/pending/$key.json" ] || mv -f "$STATE/pending/$key.json" "$STATE/claimed/$key.json"
    [ -e "$STATE/claimed/$key.json" ] || { log stopped "claim transaction lost event key $key"; exit 1; }
  done < <(jq -r '.event_keys[]' "$STATE/current.json")
  jq '.phase="claimed"' "$STATE/current.json" >"$STATE/current.json.tmp" && mv -f "$STATE/current.json.tmp" "$STATE/current.json"
fi

# Finalise only a protocol acknowledgement. Process exit is never interpreted
# as turn completion.
if [ -e "$STATE/current.json" ]; then
  launch_id="$(jq -r '.id' "$STATE/current.json")"; claimed_at="$(jq -r '.claimed_at' "$STATE/current.json")"
  phase="$(jq -r '.phase' "$STATE/current.json")"; result="$STATE/results/$launch_id.json"
  if [ -e "$result" ]; then
    status="$(jq -r '.status' "$result")"
    for f in "$STATE"/claimed/*.json; do
      [ -e "$f" ] || continue
      id="$(jq -r '.id' "$f")"; attempts="$(jq -r '.attempts' "$f")"; source="$(jq -r '.source' "$f")"; progressed=0
      if [ "$status" = 0 ] && { [ "$source" = external ] || ! grep -qxF "$id" "$ready_ids"; }; then progressed=1; fi
      key="$(event_key "$id")"
      if [ "$status" = 130 ] || [ "$status" = 126 ]; then
        mv "$f" "$STATE/stopped/$key.json"
        stop_reason=interrupted; [ "$status" = 126 ] && stop_reason=ambiguous-turn-start
        atomic_json "$ROOT/conductor.stopped" --arg event_id "$id" --arg launch_id "$launch_id" --arg reason "$stop_reason" --argjson stopped_at "$(now)" '{event_id:$event_id,launch_id:$launch_id,reason:$reason,stopped_at:$stopped_at}'
        ledger stopped --arg event_id "$id" --arg launch_id "$launch_id" --arg result "$stop_reason"
      elif [ "$progressed" -eq 1 ]; then
        mv "$f" "$STATE/consumed/$key.json"; ledger consumed --arg event_id "$id" --arg launch_id "$launch_id" --arg outcome progress
      elif [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        mv "$f" "$STATE/stopped/$key.json"
        atomic_json "$ROOT/conductor.stopped" --arg event_id "$id" --arg launch_id "$launch_id" --arg result "$status" --argjson attempts "$attempts" --argjson stopped_at "$(now)" '{event_id:$event_id,launch_id:$launch_id,result:$result,attempts:$attempts,stopped_at:$stopped_at}'
        log stopped "event '$id' made no progress after $attempts attempts; inspect $ROOT/conductor.stopped"
      else
        retry_at=$(( $(now) + RETRY_DELAY ))
        jq --argjson ready_at "$retry_at" --argjson first_seen "$retry_at" '.ready_at=$ready_at | .first_seen=$first_seen' "$f" >"$f.tmp" && mv "$f.tmp" "$STATE/pending/$key.json"
        rm -f "$f"; ledger retry --arg event_id "$id" --arg launch_id "$launch_id" --arg result "$status"
      fi
    done
    rm -f "$STATE/current.json" "$result" "$STATE/controllers/$launch_id.started"
  elif [ "$phase" = controller-starting ] && { [ -e "$STATE/controllers/$launch_id.started" ] || systemctl --user is-active --quiet "$(jq -r '.unit // empty' "$STATE/current.json")" 2>/dev/null; }; then
    skip "App Server controller owns launch $launch_id"
  elif { [ "$phase" = claimed ] || [ "$phase" = controller-starting ]; } && [ $(( $(now) - claimed_at )) -ge "$LAUNCH_GRACE" ]; then
    for f in "$STATE"/claimed/*.json; do [ ! -e "$f" ] || mv -f "$f" "$STATE/pending/$(basename "$f")"; done
    ledger recovered --arg launch_id "$launch_id" --arg boundary before-app-server-launch
    rm -f "$STATE/current.json"
  else
    skip "App Server turn active: thread $(jq -r '.thread_id // "not-yet-attachable"' "$STATE/current.json"), turn $(jq -r '.turn_id // "starting"' "$STATE/current.json")"
  fi
fi

[ ! -e "$HOLD" ] || skip "held: $HOLD exists"
if [ "$SQUAD_CONTINUATION_MODE" = native ]; then
  runtime_state="$(bash "$SCRIPT_DIR/runtime.sh" recover 2>>"$LOG")" || skip "runtime recovery unreadable"
  [ "$(printf '%s' "$runtime_state" | jq -r '.paused')" = false ] || skip "user-paused: runtime pause remains in force"
fi
usage="$(quota_line | tr '\n' ' ' | sed 's/[[:space:]]*$//')"; verdict="$(printf '%s\n' "$usage" | awk '{print $1}' | tr -d ':')"
[ "$verdict" = run ] || skip "quota: $verdict"

# Claim every event that is already ready on this tick. Future events remain
# pending for a later tick; there is no deliberate coalescing delay.
launch_id="$(date -u -d "@$(now)" '+%Y%m%dT%H%M%SZ')-$$"; event_ids=""; event_keys=""; reasons=""
for f in "$STATE"/pending/*.json; do
  [ -e "$f" ] || continue; ready_at="$(jq -r '.ready_at' "$f")"; [ "$(now)" -ge "$ready_at" ] || continue
  id="$(jq -r '.id' "$f")"; key="$(event_key "$id")"
  event_ids="${event_ids}${event_ids:+,}$id"; event_keys="${event_keys}${event_keys:+,}$key"; reasons="${reasons}${reasons:+; }$(jq -r '.reason' "$f")"
done
[ -n "$event_ids" ] || skip "no newly actionable event"
atomic_json "$STATE/current.json" --arg id "$launch_id" --arg events "$event_ids" --arg keys "$event_keys" --argjson claimed_at "$(now)" --arg phase claiming \
  '{id:$id,events:($events|split(",")),event_keys:($keys|split(",")),claimed_at:$claimed_at,phase:$phase,attachable:false}'
claimed_count=0
for key in ${event_keys//,/ }; do
  jq '.attempts += 1' "$STATE/pending/$key.json" >"$STATE/pending/$key.json.tmp" && mv -f "$STATE/pending/$key.json.tmp" "$STATE/pending/$key.json"
  mv -f "$STATE/pending/$key.json" "$STATE/claimed/$key.json"
  claimed_count=$((claimed_count + 1))
  [ "${SQUAD_CONDUCTOR_FAIL_AFTER_EVENT:-}" != "$claimed_count" ] || exit 96
done
jq '.phase="claimed"' "$STATE/current.json" >"$STATE/current.json.tmp" && mv -f "$STATE/current.json.tmp" "$STATE/current.json"
ledger claimed --arg launch_id "$launch_id" --arg events "$event_ids"
[ "${SQUAD_CONDUCTOR_FAIL_AT:-}" != after-claim ] || exit 99
brief="Use the Squad administrator skill. Reconcile durable state through squad.sh recover and handle events $event_ids ($reasons). Use native subagent notifications; keep coordinating and wait on harness events while workers run. Claim before dispatch, bind the actual worker/model, checkpoint and acknowledge results. Use squad.sh next for subsequent assignments and route stalled items/replies to the Project Manager. Settle the recovered revision only after handling it. Preserve user pauses. The handover summarises records; it is not the wake mechanism."
if [ "$dry_run" -eq 1 ]; then
  for f in "$STATE"/claimed/*.json; do [ ! -e "$f" ] || mv "$f" "$STATE/pending/$(basename "$f")"; done
  rm -f "$STATE/current.json"; log dry-run "would start '$TAB' for events: $event_ids"; exit 0
fi
[ "${SQUAD_CONDUCTOR_FAIL_AT:-}" != before-launch ] || exit 98
project_dir="$(squad_project_dir)"
client="${SQUAD_CONDUCTOR_APP_SERVER_CLIENT:-$ROOT/bin/squad-conductor-appserver}"
url="${SQUAD_CONDUCTOR_APP_SERVER_URL:-unix://$ROOT/squad-app-server-gateway.sock}"
unit="squad-conductor-turn-${launch_id//[^A-Za-z0-9_.-]/-}"
jq --arg unit "$unit" '.phase="controller-starting" | .unit=$unit' "$STATE/current.json" >"$STATE/current.json.tmp" && mv -f "$STATE/current.json.tmp" "$STATE/current.json"
if systemd-run --user --quiet --collect --unit "$unit" \
  --property=Restart=on-failure --property=RestartSec=2 \
  --property=StartLimitBurst=3 --property=StartLimitIntervalSec=infinity \
  "$client" run --model "$SQUAD_ADMINISTRATOR_MODEL" --url "$url" --state "$STATE" --launch "$launch_id" --brief "$brief" --cwd "$project_dir"; then
  : >"$STATE/controllers/$launch_id.started"
  log started "launch $launch_id, App Server controller $unit, events: $event_ids"
  ledger start --arg launch_id "$launch_id" --arg events "$event_ids" --arg usage "$usage" --arg attribution shared-or-unknown
  [ "${SQUAD_CONDUCTOR_FAIL_AT:-}" != after-launch ] || exit 97
else
  atomic_json "$STATE/acks/$launch_id.json" --arg id "$launch_id" --argjson status 125 --arg error "systemd-run failed before controller ownership" '{id:$id,status:$status,error:$error}'
  log failed "could not start App Server controller for launch $launch_id"; exit 1
fi
