#!/usr/bin/env bash
# Deterministic event/lifecycle tests. No network or paid harness is used.
set -uo pipefail
export SQUAD_CONTINUATION_MODE=legacy

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-conductor-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'pass  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected: $3" ;; esac; }
equal() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }

mkdir -p "$WORK/project/.codex" "$WORK/bin" "$WORK/scratch"
cat >"$WORK/project/.codex/squad.local.md" <<EOF
---
repository: someone/project
origin_remote: file:///unused
scratch_root: $WORK/scratch
quota_command: false
chief_of_staff: Astra
conductor_session: codex
conductor_command: $WORK/bin/fake-harness
---
EOF
cat >"$WORK/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ZELLIJ_LOG"
if [ "${FAKE_SYSTEMD_RUN_WRITE_CURRENT:-0}" = 1 ]; then
  state=""; launch=""; previous=""
  for arg in "$@"; do
    [ "$previous" != --state ] || state="$arg"
    [ "$previous" != --launch ] || launch="$arg"
    previous="$arg"
  done
  jq --arg thread thread-from-controller --arg turn turn-from-controller '.thread_id=$thread | .turn_id=$turn | .phase="turn-active"' "$state/current.json" >"$state/current.json.worker" && mv "$state/current.json.worker" "$state/current.json"
fi
exit 0
EOF
cat >"$WORK/bin/fake-harness" <<'EOF'
#!/usr/bin/env bash
sleep "${FAKE_HARNESS_SLEEP:-0}"
exit "${FAKE_HARNESS_STATUS:-0}"
EOF
chmod +x "$WORK/bin/systemd-run" "$WORK/bin/fake-harness"
export PATH="$WORK/bin:$PATH" SQUAD_SETTINGS="$WORK/project/.codex/squad.local.md"
export FAKE_ZELLIJ_LOG="$WORK/zellij.log"
# Simulate a caller with live runtime paths in its environment, then pin every
# mutable conductor path to this test's private root.
HOSTILE_STATE="$WORK/hostile-live-state"
mkdir -p "$HOSTILE_STATE"; printf 'do not touch\n' >"$HOSTILE_STATE/sentinel"
export SQUAD_CONDUCTOR_STATE="$HOSTILE_STATE"
export SQUAD_CONDUCTOR_LOG="$WORK/hostile.log"
export SQUAD_CONDUCTOR_LEDGER="$WORK/hostile-ledger.jsonl"
export SQUAD_CONDUCTOR_HOLD="$WORK/hostile.hold"
export SQUAD_CONDUCTOR_STATE="$WORK/scratch/conductor-state"
export SQUAD_CONDUCTOR_LOG="$WORK/scratch/conductor.log"
export SQUAD_CONDUCTOR_LEDGER="$WORK/scratch/conductor-ledger.jsonl"
export SQUAD_CONDUCTOR_HOLD="$WORK/scratch/conductor.hold"

handover() {
  local in_flight="${1:-None. No agent is running.}" waits="${2:-None. Nothing is waiting on a clock.}" events="${3:-None. No event is ready.}"
  printf '<!-- handover -->\n**Hand-over, 2026-09-20 20:00 UTC, sprint issue #99**\n\n## State of the tree\n\nclean\n\n## Agents in flight\n\n%s\n\n## Next actions in order\n\nHandle every ready event.\n\n## Waits\n\n%s\n\n## Wake events\n\n%s\n' "$in_flight" "$waits" "$events"
}
run() {
  local at="$1" text="$2"; shift 2
  SQUAD_CONDUCTOR_NOW="$at" SQUAD_CONDUCTOR_QUOTA=run \
    SQUAD_CONDUCTOR_RETRY_SECONDS=0 SQUAD_CONDUCTOR_LAUNCH_GRACE_SECONDS=30 \
    SQUAD_CONDUCTOR_HANDOVER="$text" "$@" bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1
  tail -1 "$WORK/scratch/conductor.log" 2>/dev/null || true
}
new_tabs() { grep -c 'squad-conductor-turn-' "$FAKE_ZELLIJ_LOG" 2>/dev/null || true; }
: >"$FAKE_ZELLIJ_LOG"

e1="- id: review-pr-1-aaa | kind: review | reason: review arrived"
export FAKE_SYSTEMD_RUN_WRITE_CURRENT=1
run 1000 "$(handover '' '' "$e1")" >/dev/null
unset FAKE_SYSTEMD_RUN_WRITE_CURRENT
equal "one ready event launches on its first check" "$(new_tabs)" 1
launch_command="$(tail -1 "$FAKE_ZELLIJ_LOG")"
has "controller retries have a finite burst" "$launch_command" "--property=StartLimitBurst=3"
has "controller retry budget cannot reset over time" "$launch_command" "--property=StartLimitIntervalSec=infinity"
equal "shell preserves controller-written turn identity" "$(jq -r .turn_id "$WORK/scratch/conductor-state/current.json")" turn-from-controller
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"
during="- id: dependency-during-active | kind: dependency | reason: became ready during coordination"
run 1001 "$(handover '' '' "$during")" >/dev/null
during_key="$(printf '%s' dependency-during-active | sha256sum | awk '{print $1}')"
[ -e "$WORK/scratch/conductor-state/pending/$during_key.json" ] \
  && ok "event observed during an active turn remains pending" \
  || bad "event observed during an active turn remains pending" "event missing"
equal "active turn prevents an overlapping launch" "$(new_tabs)" 1
SQUAD_CONDUCTOR_NOW=1002 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0
run 1003 "$(handover '' '' "$during")" >/dev/null
equal "first check after acknowledgement dispatches the retained event" "$(new_tabs)" 2
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"
SQUAD_CONDUCTOR_NOW=1004 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0
run 1005 "$(handover)" >/dev/null
run 2000 "$(handover '' '' "$e1")" >/dev/null
equal "unchanged consumed event never launches again" "$(new_tabs)" 2

printf 'DONE\n' >"$WORK/job.log"
job="- id: job-2-test | issue: #2 | log: $WORK/job.log | marker: DONE"
review="- id: review-pr-2-bbb | kind: review | reason: review arrived"
run 3000 "$(handover "$job" '' "$review")" >/dev/null
current_events="$(jq -r '.events | sort | join(",")' "$WORK/scratch/conductor-state/current.json")"
equal "multiple events ready on one tick share a turn" "$current_events" "job-2-test,review-pr-2-bbb"

# Complete that launch, then prove a later event gets its own launch.
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"
SQUAD_CONDUCTOR_NOW=3061 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0
run 3062 "$(handover)" >/dev/null
later="- id: dependency-3-data | kind: dependency | reason: source arrived"
run 4000 "$(handover '' '' "$later")" >/dev/null
equal "later event produces one further launch" "$(new_tabs)" 4

# An idle observer does not block later scheduled turns; App Server turn state,
# rather than a terminal lifetime, is the lease.
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"
SQUAD_CONDUCTOR_NOW=4061 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0
run 4062 "$(handover)" >/dev/null
before_observer="$(new_tabs)"
run 5000 "$(handover '' '' '- id: dependency-4-x | kind: dependency | reason: ready')" >/dev/null
equal "idle observer does not block a scheduled turn" "$(( $(new_tabs) - before_observer ))" 1
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"
(
  flock -x 8
  SQUAD_CONDUCTOR_NOW=5001 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0
) 8>"$WORK/scratch/conductor-state/lock"
[ -e "$WORK/scratch/conductor-state/acks/$launch.json" ] && ok "completion racing the timer lock is durable" || bad "completion racing the timer lock is durable" "ack missing"
run 5002 "$(handover)" >/dev/null
printf '%s\n' '{"thread_id":"persistent-thread","turn_id":"completed-turn","turn_status":"completed","attachable":true,"resolved":{"model":"gpt-test","cwd":"/work","approvalPolicy":"never","reasoningEffort":"medium","sandbox":{"type":"workspaceWrite"}}}' >"$WORK/scratch/conductor-state/chief-of-staff-thread.json"
out="$(bash "$SCRIPTS/conductor-session.sh" inspect)"
has "idle completed thread remains inspectable" "$out" 'persistent-thread'
printf '%s\n' '{"id":"old-launch","thread_id":"persistent-thread","turn_id":"old-scheduler-turn","turn_status":"completed","attachable":true}' >"$WORK/scratch/conductor-state/current.json"
printf '%s\n' '{"thread_id":"persistent-thread","turn_id":"new-native-turn","turn_status":"inProgress","attachable":true,"resolved":{"model":"gpt-test","cwd":"/work","approvalPolicy":"never","reasoningEffort":"medium","sandbox":{"type":"workspaceWrite"}}}' >"$WORK/scratch/conductor-state/chief-of-staff-thread.json"
out="$(bash "$SCRIPTS/conductor-session.sh" inspect)"
has "human controls prefer gateway native authority over pending scheduler acknowledgement" "$out" 'new-native-turn'
if [[ "$out" == *old-scheduler-turn* ]]; then
  bad "human controls prefer gateway native authority over pending scheduler acknowledgement" "$out"
fi
rm -f "$WORK/scratch/conductor-state/current.json"

future="- id: quota-later | until: 2030-01-01 00:00 UTC | ready: true | reason: quota reset"
before="$(new_tabs)"; run 5001 "$(handover '' "$future")" >/dev/null
equal "future wait produces no launch" "$(new_tabs)" "$before"
not_ready="- id: quota-no-work | until: 1970-01-01 00:00 UTC | reason: quota reset"
before="$(new_tabs)"; run 5001 "$(handover '' "$not_ready")" >/dev/null
equal "elapsed quota clock without agreed ready work does not launch" "$(new_tabs)" "$before"
out="$(SQUAD_CONDUCTOR_NOW=5002 SQUAD_CONDUCTOR_QUOTA=suspend SQUAD_CONDUCTOR_HANDOVER="$(handover '' '' '- id: dependency-5-x | kind: dependency | reason: ready')" bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1; tail -1 "$WORK/scratch/conductor.log")"
has "exhausted quota produces no paid start" "$out" "quota: suspend"
old="$(printf '<!-- handover -->\n\n## Agents in flight\n\nNone. No agent is running.\n\n## Next actions in order\n\ndo it\n\n## Waits\n\nNone. Nothing is waiting on a clock.\n')"
out="$(run 5003 "$old")"; has "old handover gets actionable migration error" "$out" "predates the event contract"
bad_wait="- id: quota-bad | until: <time> | reason: reset"
out="$(run 5004 "$(handover '' "$bad_wait")")"; has "placeholder wait is rejected" "$out" "placeholder"

# Three unacknowledged launches of one stable id stop, even if prose changes.
retry="- id: dependency-retry | kind: dependency | reason: wording one"
run 6000 "$(handover '' '' "$retry")" >/dev/null; run 6060 "$(handover '' '' "$retry")" >/dev/null
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"; SQUAD_CONDUCTOR_NOW=6061 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 125
run 6091 "$(handover '' '' '- id: dependency-retry | kind: dependency | reason: wording two')" >/dev/null
run 6151 "$(handover '' '' "$retry")" >/dev/null
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"; SQUAD_CONDUCTOR_NOW=6152 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 125
run 6182 "$(handover '' '' "$retry")" >/dev/null
run 6242 "$(handover '' '' "$retry")" >/dev/null
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json")"; SQUAD_CONDUCTOR_NOW=6243 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 125
run 6273 "$(handover '' '' '- id: dependency-retry | kind: dependency | reason: wording three')" >/dev/null
out="$(tail -3 "$WORK/scratch/conductor.log")"
has "three no-progress attempts stop with a diagnostic" "$out" "made no progress after 3 attempts"

# Native worker lifecycle is accepted only from the exact rollout/thread/turn.
rm -rf "$WORK/scratch/conductor-state"; mkdir -p "$WORK/scratch/conductor-state"
printf 'RUNNING\n' >"$WORK/failed-worker.log"
cat >"$WORK/failed-rollout.jsonl" <<'EOF'
{"type":"session_meta","payload":{"id":"thread-failed"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-failed","error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"server_overloaded"}}}
EOF
failed_job="- id: worker-145 | issue: #145 | log: $WORK/failed-worker.log | marker: DONE | rollout: $WORK/failed-rollout.jsonl | thread: thread-failed | turn: turn-failed"
run 7000 "$(handover "$failed_job")" >/dev/null
failed_key="$(printf '%s' 'worker-145.worker-failed' | sha256sum | awk '{print $1}')"
failed_event="$WORK/scratch/conductor-state/claimed/$failed_key.json"
[ -e "$failed_event" ] && ok "matching native failure claims one stable worker event immediately" || bad "matching native failure claims one stable worker event immediately" "event missing"
has "worker failure preserves the precise native reason" "$(jq -r .reason "$failed_event")" "server_overloaded"
has "worker failure writes visible terminal status" "$(tail -1 "$WORK/failed-worker.log")" "FAILED:"
run 7001 "$(handover "$failed_job")" >/dev/null
equal "repeated ticks keep one stable worker failure id" "$(find "$WORK/scratch/conductor-state" -name "$failed_key.json" | wc -l | tr -d ' ')" 1

printf 'RUNNING\n' >"$WORK/running-worker.log"
cat >"$WORK/running-rollout.jsonl" <<'EOF'
{"type":"session_meta","payload":{"id":"thread-running"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-running"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"unrelated-turn","error":{"message":"unrelated"}}}
EOF
running_job="- id: worker-running | issue: #8 | log: $WORK/running-worker.log | marker: DONE | rollout: $WORK/running-rollout.jsonl | thread: thread-running | turn: turn-running"
before="$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')"
run 7002 "$(handover "$running_job")" >/dev/null
equal "running worker and unrelated terminal turn queue nothing" "$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')" "$before"
equal "running worker status remains running" "$(tail -1 "$WORK/running-worker.log")" RUNNING

printf 'RUNNING\n' >"$WORK/ambiguous-worker.log"
cat >"$WORK/ambiguous-rollout.jsonl" <<'EOF'
{"type":"session_meta","payload":{"id":"thread-expected"}}
{"type":"session_meta","payload":{"id":"thread-other"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-ambiguous","error":{"message":"capacity","codex_error_info":"server_overloaded"}}}
EOF
ambiguous_job="- id: worker-ambiguous | issue: #8 | log: $WORK/ambiguous-worker.log | marker: DONE | rollout: $WORK/ambiguous-rollout.jsonl | thread: thread-expected | turn: turn-ambiguous"
before="$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')"
run 7003 "$(handover "$ambiguous_job")" >/dev/null
equal "conflicting session metadata queues nothing" "$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')" "$before"
equal "ambiguous worker status remains running" "$(tail -1 "$WORK/ambiguous-worker.log")" RUNNING
has "ambiguous session identity has a precise diagnostic" "$(tail -3 "$WORK/scratch/conductor.log")" "ambiguous session identity"

invalid_lifecycle_case() {
  local label="$1" metadata="$2" terminal="$3" diagnostic="$4" at="$5" before after status log_tail
  printf 'RUNNING\n' >"$WORK/invalid-lifecycle.log"
  printf '%s\n%s\n' "$metadata" "$terminal" >"$WORK/invalid-lifecycle.jsonl"
  before="$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')"
  run "$at" "$(handover "- id: worker-invalid | issue: #8 | log: $WORK/invalid-lifecycle.log | marker: DONE | rollout: $WORK/invalid-lifecycle.jsonl | turn: turn-invalid")" >/dev/null
  after="$(find "$WORK/scratch/conductor-state/pending" -type f | wc -l | tr -d ' ')"
  status="$(tail -1 "$WORK/invalid-lifecycle.log")"
  log_tail="$(tail -3 "$WORK/scratch/conductor.log")"
  if [ "$before" = "$after" ] && [ "$status" = RUNNING ] && [[ "$log_tail" == *"$diagnostic"* ]]; then
    ok "$label is inert with a precise diagnostic"
  else
    bad "$label is inert with a precise diagnostic" "events $before->$after, status '$status', log '$log_tail'"
  fi
}

# Every session metadata record must carry one valid, unambiguous native id.
identity_at=7004
while IFS='|' read -r label metadata; do
  invalid_lifecycle_case "$label" "$metadata" \
    '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-invalid","error":{"message":"capacity"}}}' \
    'invalid session identity' "$identity_at"
  identity_at=$((identity_at + 1))
done <<'EOF'
missing session id|{"type":"session_meta","payload":{}}
null session id|{"type":"session_meta","payload":{"id":null}}
empty session id|{"type":"session_meta","payload":{"id":""}}
whitespace session id|{"type":"session_meta","payload":{"id":"   "}}
numeric session id|{"type":"session_meta","payload":{"id":123}}
boolean session id|{"type":"session_meta","payload":{"id":true}}
array session id|{"type":"session_meta","payload":{"id":[]}}
object session id|{"type":"session_meta","payload":{"id":{}}}
EOF

# A terminal error is either absent/null (success) or an object (failure).
error_at=7012
while IFS='|' read -r label error_value; do
  invalid_lifecycle_case "$label" \
    '{"type":"session_meta","payload":{"id":"thread-invalid"}}' \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-invalid\",\"error\":$error_value}}" \
    'unsupported task_complete error shape' "$error_at"
  error_at=$((error_at + 1))
done <<'EOF'
string terminal error|"capacity"
numeric terminal error|123
boolean terminal error|true
array terminal error|[]
EOF

incomplete_job="- id: worker-incomplete | issue: #9 | log: $WORK/running-worker.log | marker: DONE | turn: turn-running"
out="$(run 7004 "$(handover "$incomplete_job")")"
has "incomplete lifecycle identity has a precise diagnostic" "$out" "lifecycle identity is incomplete"

printf 'RUNNING\n' >"$WORK/completed-worker.log"
cat >"$WORK/completed-rollout.jsonl" <<'EOF'
{"type":"session_meta","payload":{"id":"thread-completed"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-completed","last_agent_message":"finished"}}
EOF
completed_job="- id: worker-completed | issue: #10 | log: $WORK/completed-worker.log | marker: DONE | rollout: $WORK/completed-rollout.jsonl | thread: thread-completed | turn: turn-completed"
run 7005 "$(handover "$completed_job")" >/dev/null
completed_key="$(printf '%s' 'worker-completed.worker-completed' | sha256sum | awk '{print $1}')"
completed_event="$WORK/scratch/conductor-state/pending/$completed_key.json"
[ -e "$completed_event" ] && ok "markerless native success queues reconciliation" || bad "markerless native success queues reconciliation" "event missing"
has "markerless success is visibly terminal" "$(tail -1 "$WORK/completed-worker.log")" "COMPLETED:"

printf 'DONE\n' >"$WORK/legacy-job.log"
legacy_job="- id: legacy-job | issue: #11 | log: $WORK/legacy-job.log | marker: DONE"
run 7006 "$(handover "$legacy_job")" >/dev/null
legacy_key="$(printf '%s' legacy-job | sha256sum | awk '{print $1}')"
[ -e "$WORK/scratch/conductor-state/pending/$legacy_key.json" ] && ok "legacy marker-only handover remains compatible" || bad "legacy marker-only handover remains compatible" "event missing"
equal "stopped event is visible" "$(jq -r .event_id "$WORK/scratch/conductor.stopped")" dependency-retry

# Crash after claim is recovered without losing the event or an uncontrolled duplicate.
rm -rf "$WORK/scratch/conductor-state"; mkdir -p "$WORK/scratch/conductor-state"
crash="- id: dependency-crash | kind: dependency | reason: ready"
SQUAD_CONDUCTOR_NOW=7000 SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_FAIL_AT=after-claim SQUAD_CONDUCTOR_HANDOVER="$(handover '' '' "$crash")" \
  bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1 || true
run 7091 "$(handover '' '' "$crash")" >/dev/null
crash_key="$(printf '%s' dependency-crash | sha256sum | awk '{print $1}')"
recovered_attempts="$(jq -r .attempts "$WORK/scratch/conductor-state/claimed/$crash_key.json" 2>/dev/null || jq -r .attempts "$WORK/scratch/conductor-state/pending/$crash_key.json")"
[ "$recovered_attempts" -ge 1 ] && ok "restart after claim preserves its attempt" || bad "restart after claim preserves its attempt" "got $recovered_attempts"
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json" 2>/dev/null || true)"; [ -z "$launch" ] || { SQUAD_CONDUCTOR_NOW=7092 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0; run 7093 "$(handover)" >/dev/null; }

before="- id: dependency-before-launch | kind: dependency | reason: ready"
SQUAD_CONDUCTOR_NOW=8000 SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_FAIL_AT=before-launch SQUAD_CONDUCTOR_HANDOVER="$(handover '' '' "$before")" \
  bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1 || true
run 8091 "$(handover '' '' "$before")" >/dev/null
before_key="$(printf '%s' dependency-before-launch | sha256sum | awk '{print $1}')"
{ [ -e "$WORK/scratch/conductor-state/pending/$before_key.json" ] || [ -e "$WORK/scratch/conductor-state/claimed/$before_key.json" ]; } \
  && ok "restart before launch returns the claim safely" || bad "restart before launch returns the claim safely" "event missing"
launch="$(jq -r .id "$WORK/scratch/conductor-state/current.json" 2>/dev/null || true)"; [ -z "$launch" ] || { SQUAD_CONDUCTOR_NOW=8092 SQUAD_CONDUCTOR_QUOTA=run bash "$SCRIPTS/conductor.sh" --ack "$launch" 0; run 8093 "$(handover)" >/dev/null; }

after="- id: dependency-after-launch | kind: dependency | reason: ready"
SQUAD_CONDUCTOR_NOW=9000 SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_FAIL_AT=after-launch SQUAD_CONDUCTOR_HANDOVER="$(handover '' '' "$after")" \
  bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1 || true
run 9091 "$(handover '' '' "$after")" >/dev/null
[ "$(jq -r .phase "$WORK/scratch/conductor-state/current.json")" = controller-starting ] \
  && ok "restart after launch preserves protocol-owned turn" || bad "restart after launch preserves protocol-owned turn" "active transaction missing"

# A crash between event moves is completed from the journal, including all
# events in the batch.
rm -f "$WORK/scratch/conductor-state/current.json"
for f in "$WORK/scratch/conductor-state/pending"/*.json "$WORK/scratch/conductor-state/claimed"/*.json; do
  [ -e "$f" ] || continue; mv "$f" "$WORK/scratch/conductor-state/stopped/$(basename "$f")"
done
multi="- id: dependency-multi-a | kind: dependency | reason: first
- id: dependency-multi-b | kind: dependency | reason: second"
SQUAD_CONDUCTOR_NOW=9500 SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_FAIL_AFTER_EVENT=1 SQUAD_CONDUCTOR_HANDOVER="$(handover '' '' "$multi")" \
  bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1 || true
run 9591 "$(handover '' '' "$multi")" >/dev/null
equal "partial multi-event claim recovers the complete batch" \
  "$(jq -r '.events | sort | join(",")' "$WORK/scratch/conductor-state/current.json")" \
  "dependency-multi-a,dependency-multi-b"

race="- id: dependency-race | kind: dependency | reason: ready"
rm -f "$WORK/scratch/conductor-state/current.json"
for f in "$WORK/scratch/conductor-state/pending"/*.json "$WORK/scratch/conductor-state/claimed"/*.json; do
  [ -e "$f" ] || continue; mv "$f" "$WORK/scratch/conductor-state/stopped/$(basename "$f")"
done
tabs_before="$(new_tabs)"
run 10000 "$(handover '' '' "$race")" >/dev/null & one=$!
run 10000 "$(handover '' '' "$race")" >/dev/null & two=$!
wait "$one"; wait "$two"
equal "two racing ticks create one launch" "$(( $(new_tabs) - tabs_before ))" 1

ledger_text="$(cat "$WORK/scratch/conductor-ledger.jsonl")"
has "ledger records starts" "$ledger_text" '"type":"start"'
has "ledger marks usage attribution honestly" "$ledger_text" '"attribution":"shared-or-unknown"'
equal "focused suite never writes inherited live conductor state" \
  "$(find "$HOSTILE_STATE" -maxdepth 1 -type f -printf '%f\n')" sentinel
[ ! -e "$WORK/hostile.log" ] && [ ! -e "$WORK/hostile-ledger.jsonl" ] \
  && ok "focused suite never writes inherited live conductor logs" \
  || bad "focused suite never writes inherited live conductor logs" "hostile output was created"

# The installer is idempotent and migrates only a positively owned legacy timer.
TEST_GOMODCACHE="$(go env GOMODCACHE)"
TEST_GOCACHE="$(go env GOCACHE)"
INSTALL_HOME="$WORK/install-home"
mkdir -p "$INSTALL_HOME/.config/squad" "$INSTALL_HOME/.config/systemd/user"
printf 'SQUAD_PROJECT_DIR=%s\n' "$WORK/project" >"$INSTALL_HOME/.config/squad/conductor.env"
cat >"$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
exit 0
EOF
cat >"$WORK/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/systemctl" "$WORK/bin/loginctl"
export FAKE_SYSTEMCTL_LOG="$WORK/systemctl.log"; : >"$FAKE_SYSTEMCTL_LOG"
HOME="$INSTALL_HOME" GOMODCACHE="$TEST_GOMODCACHE" GOCACHE="$TEST_GOCACHE" GOPROXY=off GOSUMDB=off bash "$SCRIPTS/install-conductor.sh" --project "$WORK/project" >/dev/null
HOME="$INSTALL_HOME" GOMODCACHE="$TEST_GOMODCACHE" GOCACHE="$TEST_GOCACHE" GOPROXY=off GOSUMDB=off bash "$SCRIPTS/install-conductor.sh" --project "$WORK/project" >/dev/null
has "installer migrates a legacy timer owned by this project" "$(cat "$FAKE_SYSTEMCTL_LOG")" "disable --now squad-conductor.timer"
equal "installer enables only one per-project timer name" \
  "$(grep 'enable --now squad-conductor@' "$FAKE_SYSTEMCTL_LOG" | sort -u | wc -l | tr -d ' ')" 1
has "conductor service requires the gateway after reboot" \
  "$(cat "$INSTALL_HOME/.config/systemd/user/squad-conductor@.service")" \
  "Requires=squad-app-server-gateway@%i.service"
has "gateway service requires the App Server" \
  "$(cat "$INSTALL_HOME/.config/systemd/user/squad-app-server-gateway@.service")" \
  "Requires=squad-app-server@%i.service"
has "installer starts the static gateway chain" "$(cat "$FAKE_SYSTEMCTL_LOG")" \
  "start squad-app-server-gateway@someone-project.service"
if grep -q 'enable --now squad-app-server' "$FAKE_SYSTEMCTL_LOG"; then
  bad "installer does not enable static support units" "$(cat "$FAKE_SYSTEMCTL_LOG")"
else
  ok "installer does not enable static support units"
fi
[ -f "$INSTALL_HOME/.config/systemd/user/squad-conductor@.timer" ] \
  && ok "idempotent reinstall keeps one timer template" || bad "idempotent reinstall keeps one timer template" "template missing"
install_env="$INSTALL_HOME/.config/squad/someone-project.env"
has "installer namespaces state by project instance" "$(cat "$install_env")" "conductor-someone-project/state"
has "installer namespaces gateway by project instance" "$(cat "$install_env")" "conductor-someone-project/gateway.sock"

rm -f "$WORK/scratch/conductor-state/current.json"
printf '%s\n' '{"thread_id":"persistent-thread","turn_id":"completed-turn","turn_status":"completed","attachable":true}' >"$WORK/scratch/conductor-state/chief-of-staff-thread.json"
cat >"$WORK/bin/fake-control" <<'EOF'
#!/usr/bin/env bash
state="$SQUAD_CONDUCTOR_STATE"
mkdir -p "$state/rollovers"
mv "$state/chief-of-staff-thread.json" "$state/rollovers/test-thread.json"
EOF
chmod +x "$WORK/bin/fake-control"
SQUAD_CONDUCTOR_STATE="$WORK/scratch/conductor-state" SQUAD_CONDUCTOR_APP_SERVER_CLIENT="$WORK/bin/fake-control" \
  bash "$SCRIPTS/conductor-session.sh" rollover >/dev/null
[ ! -e "$WORK/scratch/conductor-state/chief-of-staff-thread.json" ] && [ -n "$(find "$WORK/scratch/conductor-state/rollovers" -name '*-thread.json' -print -quit)" ] \
  && ok "explicit rollover preserves the previous thread record" || bad "explicit rollover preserves the previous thread record" "archive missing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
