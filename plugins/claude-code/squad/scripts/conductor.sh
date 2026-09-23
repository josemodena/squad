#!/usr/bin/env bash
# Start a Administrator session when the quota allows and none is alive.
#
# A systemd user timer runs this every ten minutes. It starts a session only
# when all four things are true:
#
#   1. no session is alive: the terminal multiplexer holds no tab of the Chief
#      of Staff's name;
#   2. the quota command says "run";
#   3. the newest hand-over comment on the current sprint issue lists a next
#      action, which means anything other than the default "nothing recorded"
#      text the hand-over writes when it is given none;
#   4. the hold file is absent;
#   5. the last session it started left a hand-over behind, or an hour has
#      passed since that start.
#
# It never starts a second session while one is alive and it never kills one.
# Every run writes one line to the log saying what it decided and why, so a
# session that did not start can always be explained afterwards.
#
# Nothing here knows a project. The multiplexer session, the tab name, the
# harness command, the quota command, the scratch root and the sprint issue all
# come from .claude/squad.local.md or from the other Squad scripts.
#
# Options:
#   --issue <n>   the sprint issue to read, instead of the current one
#   --dry-run     decide and log, but start nothing
#
# Environment, for tests and for a hold:
#   SQUAD_PROJECT_DIR           the project whose settings to read; the timer
#                               sets it, because a service has no working
#                               directory of its own
#   SQUAD_CONDUCTOR_QUOTA       force the quota verdict
#   SQUAD_CONDUCTOR_HANDOVER    use this text as the newest hand-over
#   SQUAD_CONDUCTOR_COOLDOWN    seconds to wait after a start before another
#                               may be considered (default 120)
#   SQUAD_CONDUCTOR_BACKOFF     seconds to wait after a start that left no
#                               hand-over behind (default 3600)
#   SQUAD_CONDUCTOR_LOG         where to log (default <scratch root>/conductor.log)
set -uo pipefail

SQUAD_TOOL="conductor.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  conductor.sh [--issue <number>] [--dry-run]

  --issue     the sprint issue to read; without it, the current sprint issue
  --dry-run   decide and log, but start nothing
USAGE
  exit 1
}

issue_number=""
dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)   issue_number="${2:-}"; [ -n "$issue_number" ] || usage; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

squad_load_settings

# Observe replies without spending model capacity or changing board state.
# Errors persist a bounded backoff; normal recovery must still process other work.
if [ "$SQUAD_CONTINUATION_MODE" = native ]; then
  bash "$SCRIPT_DIR/runtime.sh" inbox poll >/dev/null 2>&1 || true
fi

SESSION="$SQUAD_CONDUCTOR_SESSION"
TAB="$SQUAD_CONDUCTOR_TAB"
HARNESS="$SQUAD_CONDUCTOR_COMMAND"
STATE_DIR="$SQUAD_SCRATCH_ROOT"
LOG="${SQUAD_CONDUCTOR_LOG:-$STATE_DIR/conductor.log}"
LOCK="$STATE_DIR/conductor.lock"
STAMP="$STATE_DIR/conductor.started"
HOLD="$STATE_DIR/conductor.hold"
ALIVE_SINCE="$STATE_DIR/conductor.alive_since"
COOLDOWN="${SQUAD_CONDUCTOR_COOLDOWN:-120}"
BACKOFF="${SQUAD_CONDUCTOR_BACKOFF:-3600}"

mkdir -p "$STATE_DIR"

log() {
  printf '%s  %-7s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$1" "$2" >>"$LOG"
}

# A decision not to start is a normal outcome, not a failure: the timer would
# mark the service failed and stop being useful as a record.
skip() { log skip "$1"; exit 0; }

# --- one run at a time ------------------------------------------------------

# The lock is held for the whole run. A second run that cannot take it says so
# and leaves; it never waits, because the timer will come round again.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || skip "lock held: another conductor run is in progress"
fi

# --- 1. is a session already alive? ----------------------------------------

command -v zellij >/dev/null 2>&1 || squad_die "zellij is not on PATH, so no session can be started."

# The query's output and its exit status are read separately, because a
# multiplexer with no session at all exits non-zero and prints
# "No active zellij sessions found."; that is readable and empty, not
# unreadable. Any other non-zero exit means the multiplexer could not be
# asked, and fails closed exactly like tab_alive below: assume alive, never
# assume free.
session_exists() {
  local out status
  out="$(zellij list-sessions --short 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$out" | grep -qxF "$SESSION"
    return
  fi
  case "$out" in
    *'No active zellij sessions found.'*) return 1 ;;
  esac
  skip "could not list the sessions of the multiplexer"
}

# A plain boolean, for the start block below. There, session_exists is asked
# again only to see whether a session it just tried to create has appeared;
# an unreadable multiplexer at that point is not "assume alive", it is
# "not yet", and the retry loop or the failure log after it handles that.
session_exists_quiet() {
  zellij list-sessions --short 2>/dev/null | grep -qxF "$SESSION"
}

# The query's output and its exit status are read separately, because a
# multiplexer that cannot be asked prints nothing and an empty answer reads
# exactly like "no tab of that name". An unreadable multiplexer means "assume
# alive", never "assume free": the one mistake that costs work is a second
# session started beside a live one.
tab_alive() {
  local names status
  names="$(zellij --session "$SESSION" action query-tab-names 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    skip "could not read the tabs of session '$SESSION'"
  fi
  printf '%s\n' "$names" | sed -e 's/\r$//' | grep -qxF "$TAB"
}

# The duration comes from a stamp of when this tab was first seen alive, not
# from counting runs, so it survives the timer being reconfigured. It is what
# lets a busy session read differently from a tab orphaned by a hard kill: a
# session-end that never ran leaves the name in place indefinitely, and the
# growing figure here is the tell.
if session_exists && tab_alive; then
  now="$(date -u +%s)"
  first_seen="$(cat "$ALIVE_SINCE" 2>/dev/null || true)"
  case "$first_seen" in
    (*[!0-9]*|'') first_seen="$now"; printf '%s\n' "$now" >"$ALIVE_SINCE" ;;
  esac
  age=$(( now - first_seen ))
  skip "session alive: a tab named '$TAB' is open in session '$SESSION', seen alive for ${age}s"
else
  rm -f "$ALIVE_SINCE" 2>/dev/null || true
fi

# --- 2. was one started a moment ago? --------------------------------------

# A tab takes a second or two to appear. Without this, two runs close together
# could both decide that nothing was alive.
# The stamp holds the time of the last start, in seconds since the epoch.
# Anything else in it counts as no start at all.
stamp_seconds() {
  local value
  value="$(cat "$STAMP" 2>/dev/null || true)"
  case "$value" in (*[!0-9]*|'') return 1 ;; esac
  printf '%s\n' "$value"
}

if started_at="$(stamp_seconds)" && [ "$COOLDOWN" -gt 0 ] 2>/dev/null; then
  age=$(( $(date -u +%s) - started_at ))
  if [ "$age" -lt "$COOLDOWN" ]; then
    skip "started ${age}s ago: waiting ${COOLDOWN}s before considering another"
  fi
fi

# --- 3. the hold ------------------------------------------------------------

if [ -e "$HOLD" ]; then
  skip "held: $HOLD exists; remove it to let the conductor start sessions"
fi

# --- 4. the quota -----------------------------------------------------------

# The quota command prints its verdict as the first word of its first line.
quota_verdict() {
  local bin out
  if [ -n "${SQUAD_CONDUCTOR_QUOTA:-}" ]; then printf '%s\n' "$SQUAD_CONDUCTOR_QUOTA"; return 0; fi
  bin="$(command -v "$SQUAD_QUOTA_COMMAND" 2>/dev/null || true)"
  [ -n "$bin" ] || [ ! -x "$SCRIPT_DIR/$SQUAD_QUOTA_COMMAND" ] || bin="$SCRIPT_DIR/$SQUAD_QUOTA_COMMAND"
  [ -n "$bin" ] || { printf 'unreadable\n'; return 0; }
  out="$("$bin" 2>&1)" || true
  printf '%s\n' "$out" | head -1 | awk '{print $1}' | tr -d ':'
}

verdict="$(quota_verdict)"
[ "$verdict" = "run" ] || skip "quota: $verdict"

if [ "$SQUAD_CONTINUATION_MODE" = native ]; then
  recovery="$(bash "$SCRIPT_DIR/runtime.sh" wake 2>>"$LOG")" || skip "runtime recovery unreadable"
  [ "$(printf '%s' "$recovery" | jq -r '.ready')" = true ] || skip "no durable recovery work"
else
# --- 5. the sprint issue and its newest hand-over ---------------------------

if [ -z "$issue_number" ]; then
  issue_number="$(bash "$SCRIPT_DIR/squad.sh" sprint-issue 2>/dev/null)" || issue_number=""
  [ -n "$issue_number" ] || skip "no current sprint issue could be read from $SQUAD_REPOSITORY"
fi

if [ -n "${SQUAD_CONDUCTOR_HANDOVER:-}" ]; then
  handover="$SQUAD_CONDUCTOR_HANDOVER"
else
  handover="$(bash "$SCRIPT_DIR/handover.sh" --latest --issue "$issue_number" 2>/dev/null)" || handover=""
fi

[ -n "$handover" ] || skip "no hand-over comment on issue #$issue_number"

next_actions="$(printf '%s\n' "$handover" | squad_handover_section "$SQUAD_HANDOVER_NEXT_HEADING")"

[ -n "$next_actions" ] \
  || skip "no next action on issue #$issue_number: the hand-over's '$SQUAD_HANDOVER_NEXT_HEADING' section is empty"
[ "$next_actions" != "$SQUAD_HANDOVER_NEXT_DEFAULT" ] \
  || skip "no next action on issue #$issue_number: the hand-over records none"

# --- 6. did the last start leave a hand-over? -------------------------------

# A session that starts and then dies without writing a hand-over leaves the
# same next actions on the issue, so the next run would start another, and
# another, every ten minutes for nothing. When the stamp of the last start is
# newer than the hand-over being read, that start wrote no record: wait for a
# new hand-over, or for the hour to pass, before spending on another.
#
# A hand-over with no readable time is left alone. Unknown is not old.
if started_at="$(stamp_seconds)" && [ "$BACKOFF" -gt 0 ] 2>/dev/null; then
  handover_at="$(printf '%s\n' "$handover" | squad_handover_time)"
  if [ -n "$handover_at" ] && [ "$started_at" -gt "$handover_at" ]; then
    age=$(( $(date -u +%s) - started_at ))
    if [ "$age" -lt "$BACKOFF" ]; then
      skip "last start left no hand-over: backing off"
    fi
  fi
fi

fi # legacy handover compatibility

# --- 7. start ---------------------------------------------------------------

brief="Use the Squad administrator skill. Read issue #${issue_number} for legacy narrative context. Read squad.sh recover, handle durable results and use native subagent notifications to keep work moving. Claim and checkpoint assignments. Preserve user pauses. Read the latest handover for narrative context."
project_dir="$(squad_project_dir)"

if [ "$dry_run" -eq 1 ]; then
  log dry-run "would open tab '$TAB' in session '$SESSION' running: $HARNESS \"$brief\""
  exit 0
fi

if ! session_exists; then
  # After a reboot there is no session to open a tab in. Creating a detached
  # one is safe: it never touches a session that is already there.
  zellij attach --create-background "$SESSION" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    session_exists_quiet && break
    sleep 1
  done
  session_exists_quiet || { log failed "session '$SESSION' does not exist and could not be created"; exit 1; }
  log created "session '$SESSION' created detached"
fi

date -u +%s >"$STAMP"

# new-tab prints the new tab's identifier. Logging it means the tab this run
# opened can later be named exactly, without guessing from a name or a focus.
if tab_id="$(zellij --session "$SESSION" action new-tab \
     --name "$TAB" --cwd "$project_dir" --close-on-exit \
     -- "$HARNESS" --model "$SQUAD_ADMINISTRATOR_MODEL" "$brief" 2>/dev/null)"; then
  log started "tab '$TAB' (id ${tab_id:-unknown}) in session '$SESSION', cwd $project_dir, brief: $brief"
else
  log failed "could not open tab '$TAB' in session '$SESSION'"
  exit 1
fi
