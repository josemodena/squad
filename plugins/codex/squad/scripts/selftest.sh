#!/usr/bin/env bash
# Mechanical checks over the Squad scripts. No network, no GitHub, no board:
# it builds a scratch repository under TMPDIR with a fake gh on PATH and
# asserts over what the scripts actually print and do.
#
#   bash scripts/selftest.sh
#
# It prints one line per check and ends with a count. Exit 0 when every check
# passed, 1 otherwise.
set -uo pipefail
export SQUAD_CONTINUATION_MODE=legacy

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-selftest-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'pass  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }

check_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) bad "$name" "expected to find: $needle" ;;
  esac
}

check_absent() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) bad "$name" "did not expect to find: $needle" ;;
    *) ok "$name" ;;
  esac
}

check_equal() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got '$got', wanted '$want'"; fi
}

# --- a fake gh, so nothing reaches the network ------------------------------

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api graphql")
    # A GraphQL answer can be staged in a file, so a script that reads the
    # board can be checked without a board.
    if [ -n "${FAKE_GH_GRAPHQL:-}" ] && [ -r "$FAKE_GH_GRAPHQL" ]; then
      cat "$FAKE_GH_GRAPHQL"
      exit 0
    fi
    ;;
esac
printf 'fake gh called: %s\n' "$*" >> "$FAKE_GH_LOG"
exit 0
FAKE
chmod +x "$WORK/bin/gh"
export FAKE_GH_LOG="$WORK/gh.log"
: > "$FAKE_GH_LOG"
PATH="$WORK/bin:$PATH"
export PATH

# --- a project with settings ------------------------------------------------

PROJECT="$WORK/project"
mkdir -p "$PROJECT/.codex"
cat > "$PROJECT/.codex/squad.local.md" <<'SETTINGS'
---
repository: someone/some-repo        # a trailing comment must not survive
project_owner: someone
project_number: 9
origin_remote: "file:///does/not/matter"
decider: A Person
decider_label: action-for-decider
chief_of_staff: A Person
chief_of_staff_model: gpt-6-astra
implementer_model: gpt-5.6-sol
reviewer_model: gpt-5.6-sol
clerk_model: gpt-5.6-luna
quota_daily_percent: 20
quota_weekly_cap_percent: 60
sprint_hour_utc: 9
tracks: [Alpha, "Beta Gamma"]
owners:
  - A Person
  - The Lead
---

Body text, which the parser must ignore.
SETTINGS
export SQUAD_SETTINGS="$PROJECT/.codex/squad.local.md"

# --- 1. the front matter parser ---------------------------------------------

parsed="$(awk -f "$SCRIPTS/lib/frontmatter.awk" "$SQUAD_SETTINGS")"
check_contains "parser: a scalar"            "$parsed" "SQUAD_REPOSITORY='someone/some-repo'"
check_contains "parser: a quoted scalar"     "$parsed" "SQUAD_ORIGIN_REMOTE='file:///does/not/matter'"
check_contains "parser: an inline list"      "$parsed" "SQUAD_TRACKS='Alpha
Beta Gamma'"
check_contains "parser: a block list"        "$parsed" "SQUAD_OWNERS='A Person
The Lead'"
check_absent   "parser: the body is ignored" "$parsed" "Body text"
check_absent   "parser: a trailing comment is stripped" "$parsed" "a trailing comment"

# --- 2. squad.sh settings and validation ------------------------------------

out="$(bash "$SCRIPTS/squad.sh" settings 2>&1)"
check_contains "settings: the repository"   "$out" "someone/some-repo"
check_contains "settings: the tracks"       "$out" "Alpha, Beta Gamma"
check_contains "settings: the owners"       "$out" "A Person, The Lead"
check_contains "settings: the quota shape"  "$out" "20% a day, 60% a week"
check_contains "settings: the decider"      "$out" "A Person (label action-for-decider)"

models="$(bash "$SCRIPTS/squad.sh" models)"
check_equal "settings: six role models" "$(printf '%s' "$models" | jq 'length')" "6"
check_contains "settings: administrator configured" "$models" '"administrator"'
check_contains "settings: separate architecture reviewer" "$models" '"architecture-reviewer"'
check_contains "settings: separate engineering reviewer" "$models" '"engineering-reviewer"'

out="$(bash "$SCRIPTS/squad.sh" move 12 Nonsense 2>&1)"; rc=$?
check_contains "move: an unknown status is refused" "$out" "Status must be one of: Backlog, This sprint"
check_equal    "move: and it exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

out="$(bash "$SCRIPTS/squad.sh" issue "A title" --track Nope --owner "A Person" 2>&1)"
check_contains "issue: an unknown track is refused" "$out" "--track must be one of: Alpha, Beta Gamma"

out="$(bash "$SCRIPTS/squad.sh" issue "A title" --track Alpha --owner "Nobody" 2>&1)"
check_contains "issue: an unknown owner is refused" "$out" "--owner must be one of: A Person, The Lead"

out="$(bash "$SCRIPTS/squad.sh" move 12 "in-progress" 2>&1)"
check_absent   "move: a status given as a slug is accepted" "$out" "Status must be one of"

out="$(bash "$SCRIPTS/squad.sh" issue "A title" --track "beta-gamma" --owner "a-person" --body "x" 2>&1)"
check_absent   "issue: a track and owner given as slugs are accepted" "$out" "must be one of"

out="$(bash "$SCRIPTS/squad.sh" needed-by 12 31-10-2026 2>&1)"
check_contains "needed-by: a bad date is refused" "$out" "The date must read YYYY-MM-DD"

out="$(SQUAD_SETTINGS="$WORK/nothing.md" bash "$SCRIPTS/squad.sh" board 2>&1)"
check_contains "settings: a missing file is named" "$out" "cannot be read"

# --- 3. gitw.sh guards ------------------------------------------------------

REPOA="$WORK/repo"
mkdir -p "$REPOA/.codex"
cp "$SQUAD_SETTINGS" "$REPOA/.codex/squad.local.md"
git -C "$REPOA" init -q -b main
git -C "$REPOA" config user.name "Test"
git -C "$REPOA" config user.email "test@example.com"
printf 'one\n' > "$REPOA/file.txt"
git -C "$REPOA" add -A
git -C "$REPOA" commit -q -m "first"

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" save "msg" 2>&1)"
check_contains "gitw: save without paths is refused" "$out" "Scoped paths are required"

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" save "msg" -- file.txt 2>&1)"
check_contains "gitw: save on main is refused" "$out" "Refusing to commit directly to main"

git -C "$REPOA" checkout -q -b piece-1-x
out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" save-all "msg" 2>&1)"
check_contains "gitw: save-all with nothing to commit is refused" "$out" "Nothing to commit"

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" finish 1 abc 2>&1)"
check_contains "gitw: a non-numeric issue is refused" "$out" "must contain digits only"

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" status 2>&1)"
check_contains "gitw: status names the branch" "$out" "piece-1-x"

# origin points somewhere else than the settings say
git -C "$REPOA" remote add origin "file://$WORK/elsewhere"
out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/gitw.sh" doctor 2>&1)"
check_contains "gitw: doctor catches the wrong origin" "$out" "the settings say 'file:///does/not/matter'"

# --- 4. the current sprint issue --------------------------------------------

# Three sprint issues, as the board and the bodies would give them back. Only
# one carries a status; the windows are written around the clock so the test
# reads the same at any hour.
sprint_node() {  # number, board status ("" for none), window start, window end
  jq -nc --arg n "$1" --arg status "$2" --arg start "$3" --arg end "$4" '
    {
      number: ($n | tonumber),
      body: "## Sprint window in UTC\n\nStart: \($start)\nEnd: \($end)\n",
      projectItems: { nodes: [ {
        project: { number: 9 },
        fieldValues: { nodes: ( [ {} ]
          + (if $status == "" then [] else [ { name: $status, field: { name: "Status" } } ] end) ) }
      } ] }
    }'
}

fmt() {
  python3 - "$1" <<'PY'
import datetime as d, sys
amount, unit = sys.argv[1].split()
delta = d.timedelta(**{unit: int(amount)})
print((d.datetime.now(d.timezone.utc) + delta).strftime('%a %d %b %Y %H:%M UTC'))
PY
}
NOW_START="$(fmt '-1 hours')"; NOW_END="$(fmt '+1 hours')"
PAST_START="$(fmt '-8 days')"; PAST_END="$(fmt '-1 days')"
NEXT_START="$(fmt '+1 days')"; NEXT_END="$(fmt '+8 days')"

# #102 is In progress, #103 is the newest, and it is #101 whose window contains
# now. The board must win over both.
{ sprint_node 103 ""            "$PAST_START" "$PAST_END"
  sprint_node 102 "In progress" "$NEXT_START" "$NEXT_END"
  sprint_node 101 ""            "$NOW_START"  "$NOW_END"
} | jq -sc '{data: {repository: {issues: {nodes: .}}}}' > "$WORK/sprint-board.json"

# The same three with nothing In progress, so the window decides.
{ sprint_node 103 "" "$PAST_START" "$PAST_END"
  sprint_node 102 "" "$NEXT_START" "$NEXT_END"
  sprint_node 101 "" "$NOW_START"  "$NOW_END"
} | jq -sc '{data: {repository: {issues: {nodes: .}}}}' > "$WORK/sprint-window.json"

# And with neither rule answering.
{ sprint_node 103 "" "$PAST_START" "$PAST_END"
  sprint_node 102 "" "$NEXT_START" "$NEXT_END"
  sprint_node 101 "" "$PAST_START" "$PAST_END"
} | jq -sc '{data: {repository: {issues: {nodes: .}}}}' > "$WORK/sprint-none.json"

out="$(FAKE_GH_GRAPHQL="$WORK/sprint-board.json" bash "$SCRIPTS/squad.sh" sprint-issue 2>&1)"
check_equal "sprint issue: the In progress one, not the newest" "$out" "102"

if date -u -d 'now' +%s >/dev/null 2>&1; then
  out="$(FAKE_GH_GRAPHQL="$WORK/sprint-window.json" bash "$SCRIPTS/squad.sh" sprint-issue 2>&1)"
  check_equal "sprint issue: the window decides when the board is silent" "$out" "101"

  out="$(FAKE_GH_GRAPHQL="$WORK/sprint-none.json" bash "$SCRIPTS/squad.sh" sprint-issue 2>&1)"; rc=$?
  check_contains "sprint issue: with neither rule it asks for one" "$out" "Name it with --issue"
  check_equal    "sprint issue: and it exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
else
  printf 'skip  sprint issue: window parsing requires GNU date (Linux runtime target)\n'
fi

# --- 5. the hand-over -------------------------------------------------------

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" \
  bash "$SCRIPTS/handover.sh" --dry-run --in-flight "one agent" --next "do a thing" --waits "17:00 UTC")"
check_contains "handover: the marker is the first line" "$(printf '%s' "$out" | head -1)" "<!-- handover -->"
check_contains "handover: state of the tree"   "$out" "## State of the tree"
check_contains "handover: agents in flight"    "$out" "## Agents in flight"
check_contains "handover: next actions"        "$out" "## Next actions in order"
check_contains "handover: waits"               "$out" "## Waits"
check_contains "handover: the branch is read"  "$out" "piece-1-x"
check_contains "handover: what was passed in"  "$out" "one agent"

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/handover.sh" --dry-run)"
check_contains "handover: an empty section says so" "$out" "None. No agent is running."

out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" \
  FAKE_GH_GRAPHQL="$WORK/sprint-board.json" bash "$SCRIPTS/handover.sh" --dry-run)"
check_contains "handover: the header names the current sprint issue" "$out" "sprint issue #102"

# --- 6. the quota -----------------------------------------------------------

cat > "$WORK/usage.json" <<USAGE
{"captured_at": $(date -u +%s), "seven_day": {"used_percentage": 10.0, "resets_at": $(( $(date -u +%s) + 4 * 86400 ))}}
USAGE
out="$(SQUAD_USAGE_FILE="$WORK/usage.json" "$SCRIPTS/codex-quota" --no-refresh --json 2>&1)"
check_contains "quota: the daily percentage comes from the settings" "$out" '"daily": 20.0'
check_contains "quota: the cap comes from the settings"              "$out" '"cap": 60.0'

out="$(SQUAD_USAGE_FILE="$WORK/usage.json" SQUAD_QUOTA_FORCE=suspend "$SCRIPTS/codex-quota" 2>&1)"; rc=$?
check_contains "quota: the verdict can be forced"    "$out" "suspend:"
check_equal    "quota: a forced suspend exits 1"     "$rc" "1"

out="$(SQUAD_USAGE_FILE="$WORK/nothing.json" "$SCRIPTS/codex-quota" --no-refresh 2>&1)"; rc=$?
check_contains "quota: a missing reading says so"    "$out" "missing:"
check_equal    "quota: and exits 3"                  "$rc" "3"

out="$(SQUAD_USAGE_FILE="$WORK/recorded.json" SQUAD_QUOTA_LEDGER="$WORK/ledger.jsonl" \
  "$SCRIPTS/codex-quota" record --used 12.5 --resets-at "$(( $(date -u +%s) + 86400 ))" \
  --issue 42 --event start 2>&1)"
check_contains "quota: a Codex reading can be recorded" "$out" "recorded: weekly 12.5%"
check_contains "quota: the piece ledger records the issue" "$(cat "$WORK/ledger.jsonl")" '"issue":42'

cat > "$WORK/bin/codex-rate-limits" <<'FAKE'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"id":0,"result":{"userAgent":"fake"}}'
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '%s\n' '{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":300,"resetsAt":1789941600},"secondary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":1790534416}}}}'
      ;;
  esac
done
FAKE
chmod +x "$WORK/bin/codex-rate-limits"
out="$(SQUAD_USAGE_FILE="$WORK/refreshed.json" \
  SQUAD_CODEX_COMMAND="$WORK/bin/codex-rate-limits" \
  "$SCRIPTS/codex-quota" --json 2>&1)"
check_contains "quota: app-server refresh reads the seven-day window" "$out" '"weekly_used": 5.0'
check_contains "quota: app-server refresh records the reset" \
  "$(cat "$WORK/refreshed.json")" '"resets_at": 1790534416'
check_contains "quota: app-server refresh records its source" \
  "$(cat "$WORK/refreshed.json")" 'account/rateLimits/read'

out="$(SQUAD_USAGE_FILE="$WORK/refreshed.json" \
  SQUAD_QUOTA_LEDGER="$WORK/refreshed-ledger.jsonl" \
  SQUAD_CODEX_COMMAND="$WORK/bin/codex-rate-limits" \
  "$SCRIPTS/codex-quota" refresh --issue 42 --event finish 2>&1)"
check_contains "quota: an automatic refresh can be recorded for a piece" \
  "$out" "recorded: weekly 5.0%"
check_contains "quota: the refreshed piece reading reaches the ledger" \
  "$(cat "$WORK/refreshed-ledger.jsonl")" '"event":"finish"'

out="$(SQUAD_USAGE_FILE="$WORK/usage.json" SQUAD_CODEX_COMMAND=/bin/false \
  "$SCRIPTS/codex-quota" --json 2>&1)"
check_contains "quota: a failed refresh keeps the previous snapshot" "$out" '"weekly_used": 10.0'

# --- 7. the hooks -----------------------------------------------------------

out="$(cd "$WORK" && SQUAD_SETTINGS="" CODEX_PROJECT_DIR="$WORK/none" bash "$ROOT/hooks/scripts/session-start.sh" 2>&1)"
check_contains "session start: a quota line is always printed" "$out" "quota: "
check_contains "session start: no settings is said plainly"    "$out" "Run the Squad init skill"

out="$(cd "$REPOA" && printf '{}' | bash "$ROOT/hooks/scripts/stop-dirty-tree.sh" 2>&1)"
check_equal "stop hook: a clean tree says nothing" "$out" ""

printf 'two\n' > "$REPOA/file.txt"
out="$(cd "$REPOA" && printf '{}' | bash "$ROOT/hooks/scripts/stop-dirty-tree.sh" 2>&1)"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["continue"] is True and "unsaved" in d["systemMessage"] else 1)'; then
  ok "stop hook: a dirty tree warns in valid JSON and does not block"
else
  bad "stop hook: a dirty tree warns in valid JSON and does not block" "$out"
fi

# --- 7b. the conductor ------------------------------------------------------

# The event-driven conductor has a focused fake-time, fake-process and race
# suite below. Keep these predecessor assertions as history until the next
# cleanup rather than making them describe the retired tab/back-off design.
if false; then

# A fake zellij, so the decisions can be checked without a multiplexer. It
# records what it was asked to do and answers with the tab names staged in
# FAKE_ZELLIJ_TABS.
cat > "$WORK/bin/zellij" <<'FAKE'
#!/usr/bin/env bash
printf 'zellij %s\n' "$*" >> "$FAKE_ZELLIJ_LOG"
args="$*"
case "$args" in
  *"list-sessions"*)
    if [ -n "${FAKE_ZELLIJ_LIST_FAILS:-}" ]; then
      printf '%s' "${FAKE_ZELLIJ_LIST_OUTPUT:-}"
      exit "$FAKE_ZELLIJ_LIST_FAILS"
    fi
    printf '%s\n' "${FAKE_ZELLIJ_SESSION:-codex}"
    ;;
  *"query-tab-names"*)
    # A multiplexer that cannot answer prints nothing and fails, which is what
    # makes the exit status the only thing that tells the two cases apart.
    [ -z "${FAKE_ZELLIJ_QUERY_FAILS:-}" ] || exit 1
    printf '%s\n' ${FAKE_ZELLIJ_TABS:-}
    ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/zellij"

export FAKE_ZELLIJ_LOG="$WORK/zellij.log"
CONDUCTOR_LOG="$WORK/conductor.log"
CONDUCTOR_STATE="$WORK/conductor-state"
mkdir -p "$CONDUCTOR_STATE"

conductor() {
  : > "$CONDUCTOR_LOG"
  : > "$FAKE_ZELLIJ_LOG"
  (
    cd "$REPOA" || exit 1
    SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" \
    SQUAD_SCRATCH_ROOT="$CONDUCTOR_STATE" \
    SQUAD_CONDUCTOR_LOG="$CONDUCTOR_LOG" \
    SQUAD_CONDUCTOR_COOLDOWN=0 \
    "$@" bash "$SCRIPTS/conductor.sh" --issue 99 >/dev/null 2>&1
  )
  cat "$CONDUCTOR_LOG"
}

handover_with() {
  printf '<!-- handover -->\n\n## Agents in flight\n\nNone. No agent is running.\n\n## Next actions in order\n\n%s\n\n## Waits\n\nNone. Nothing is waiting on a clock.\n' "$1"
}

# The same, with the header line the hand-over writes, dated $1 seconds ago.
handover_written() {
  printf '<!-- handover -->\n**Hand-over, %s, sprint issue #99**\n\n## Agents in flight\n\nNone. No agent is running.\n\n## Next actions in order\n\ndo a thing\n\n## Waits\n\nNone. Nothing is waiting on a clock.\n' \
    "$(date -u -d "@$(( $(date -u +%s) - $1 ))" '+%Y-%m-%d %H:%M UTC')"
}

# The tab name is the Chief of Staff's name, taken from the settings.
out="$(cd "$REPOA" && SQUAD_SETTINGS="$REPOA/.codex/squad.local.md" bash "$SCRIPTS/squad.sh" settings 2>&1)"
check_contains "conductor: the tab names the project and Chief of Staff" "$out" "tab someone-some-repo-a-person"

out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run FAKE_ZELLIJ_TABS="someone-some-repo-a-person" \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: a live session stops it" "$out" "session alive"

# The skip line carries how long the tab has been seen alive, so a tab
# orphaned by a hard kill (seen alive for a long time) reads differently from
# a session that has just become busy.
printf '%s\n' "$(( $(date -u +%s) - 500 ))" > "$CONDUCTOR_STATE/conductor.alive_since"
out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run FAKE_ZELLIJ_TABS="someone-some-repo-a-person" \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
if [[ "$out" =~ seen\ alive\ for\ ([0-9]+)s ]]; then
  duration="${BASH_REMATCH[1]}"
  # Allow a second or two of slack for the subprocesses this test runs
  # through; the point is that it reflects the stamp, not stopwatch
  # precision.
  if [ "$duration" -ge 500 ] && [ "$duration" -le 505 ]; then
    ok "conductor: the duration reflects the first-seen stamp"
  else
    bad "conductor: the duration reflects the first-seen stamp" "got ${duration}s, wanted about 500s"
  fi
else
  bad "conductor: the duration reflects the first-seen stamp" "no duration in: $out"
fi
rm -f "$CONDUCTOR_STATE/conductor.alive_since"

# An unreadable multiplexer must read as alive. The tab is there; the query
# fails; nothing may start.
out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run FAKE_ZELLIJ_TABS="someone-some-repo-a-person" \
  FAKE_ZELLIJ_QUERY_FAILS=1 \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: an unreadable tab query stops it" "$out" "could not read the tabs of session"
check_absent   "conductor: and starts nothing"               "$(cat "$FAKE_ZELLIJ_LOG")" "new-tab"

# An unlistable multiplexer fails closed the same way: the tab is staged as
# though present, but list-sessions itself cannot even be asked (here, exit 2
# with no "No active zellij sessions found." on its output).
out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run FAKE_ZELLIJ_TABS="someone-some-repo-a-person" \
  FAKE_ZELLIJ_LIST_FAILS=2 \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: an unlistable multiplexer stops it" "$out" "could not list the sessions of the multiplexer"
check_absent   "conductor: and starts nothing either"          "$(cat "$FAKE_ZELLIJ_LOG")" "new-tab"

out="$(conductor env SQUAD_CONDUCTOR_QUOTA=suspend \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: a suspended quota stops it" "$out" "quota: suspend"

out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'None recorded. The next session picks the next piece from the board.')")"
check_contains "conductor: the default next-action text is no action" "$out" "records none"

printf 'RUNNING\n' > "$WORK/pending.log"
pending_handover="$(printf '<!-- handover -->\n\n## Agents in flight\n\n- #42 | branch: piece-42-x | log: %s | marker: DONE\n\n## Next actions in order\n\nread the result\n\n## Waits\n\nNone. Nothing is waiting on a clock.\n' "$WORK/pending.log")"
out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run SQUAD_CONDUCTOR_HANDOVER="$pending_handover")"
check_contains "conductor: unfinished background work stops a relaunch" "$out" "has not reached marker 'DONE'"

touch "$CONDUCTOR_STATE/conductor.hold"
out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: the hold file stops it" "$out" "held:"
rm -f "$CONDUCTOR_STATE/conductor.hold"

if date -u -d '@0' '+%Y' >/dev/null 2>&1; then
  # A start that left no hand-over behind must not be repeated on every tick.
  # The stamp is newer than the hand-over, so the last session wrote nothing.
  date -u +%s > "$CONDUCTOR_STATE/conductor.started"
  out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
    SQUAD_CONDUCTOR_HANDOVER="$(handover_written 600)")"
  check_contains "conductor: a start that left no hand-over backs off" "$out" "last start left no hand-over: backing off"

  # An hour later it tries again.
  printf '%s\n' "$(( $(date -u +%s) - 4000 ))" > "$CONDUCTOR_STATE/conductor.started"
  out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
    SQUAD_CONDUCTOR_HANDOVER="$(handover_written 5000)")"
  check_contains "conductor: the backoff ends after an hour" "$out" "tab 'someone-some-repo-a-person'"

  # A hand-over written since the last start clears it at once.
  date -u +%s > "$CONDUCTOR_STATE/conductor.started"
  out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
    SQUAD_CONDUCTOR_HANDOVER="$(handover_written -120)")"
  check_contains "conductor: a newer hand-over clears the backoff" "$out" "tab 'someone-some-repo-a-person'"
  rm -f "$CONDUCTOR_STATE/conductor.started"
else
  printf 'skip  conductor: restart backoff parsing requires GNU date (Linux runtime target)\n'
fi

out="$(conductor env SQUAD_CONDUCTOR_QUOTA=run \
  SQUAD_CONDUCTOR_HANDOVER="$(handover_with 'do a thing')")"
check_contains "conductor: otherwise it starts a session" "$out" "tab 'someone-some-repo-a-person'"
check_contains "conductor: with the hand-over brief"      "$out" "issue #99"
zlog="$(cat "$FAKE_ZELLIJ_LOG")"
check_contains "conductor: it opens a tab of that name"   "$zlog" "new-tab --name someone-some-repo-a-person"
check_contains "conductor: running the harness command"   "$zlog" "-- codex Use the Squad operate skill. Read the latest hand-over comment on issue #99"
check_absent   "conductor: never kills a tab"              "$zlog" "kill-tab"
check_absent   "conductor: never kills a session"          "$zlog" "kill-session"
fi

if TMPDIR="$WORK" bash "$SCRIPTS/test-conductor-events.sh"; then
  ok "conductor: focused event and lifecycle suite"
else
  bad "conductor: focused event and lifecycle suite" "see failures above"
fi

# --- 7d. the sprint sets both board fields ----------------------------------

# One staged GraphQL answer serves both the project query and the item query,
# so "sprint" can run end to end against the fake gh.
cat > "$WORK/project.json" <<'STAGED'
{
  "data": {
    "user": {
      "projectV2": {
        "id": "PRJ",
        "title": "A board",
        "url": "https://example.invalid",
        "fields": { "nodes": [
          { "id": "F_SPRINT", "name": "Sprint", "options": [
            { "id": "OPT2", "name": "Sprint 2 (19 to 26 Sep 2026)" },
            { "id": "OPT1", "name": "Sprint 1" } ] },
          { "id": "F_ITER", "name": "Iteration", "configuration": {
            "iterations": [
              { "id": "IT10", "title": "Sprint 10", "startDate": "2026-11-21", "duration": 7 },
              { "id": "ITSHORT", "title": "Sprint", "startDate": "2026-09-19", "duration": 7 },
              { "id": "IT2",  "title": "Sprint 2",  "startDate": "2026-09-19", "duration": 7 } ],
            "completedIterations": [
              { "id": "IT1", "title": "Sprint 1", "startDate": "2026-09-12", "duration": 7 } ] } }
        ] }
      }
    },
    "repository": { "issue": { "projectItems": { "nodes": [
      { "id": "ITEM", "project": { "id": "PRJ" } } ] } } }
  }
}
STAGED

: > "$FAKE_GH_LOG"
out="$(FAKE_GH_GRAPHQL="$WORK/project.json" bash "$SCRIPTS/squad.sh" sprint 12 "Sprint 2 (19 to 26 Sep 2026)" 2>&1)"
ghlog="$(cat "$FAKE_GH_LOG")"
check_contains "sprint: it says which sprint"     "$out" "issue #12 is in sprint Sprint 2 (19 to 26 Sep 2026)"
check_contains "sprint: and which iteration"      "$out" "issue #12 is in iteration Sprint 2"
check_contains "sprint: the single-select is set" "$ghlog" "--field-id F_SPRINT --single-select-option-id OPT2"
check_contains "sprint: the iteration too"        "$ghlog" "--field-id F_ITER --iteration-id IT2"
check_absent   "sprint: not the one it merely prefixes" "$ghlog" "--iteration-id IT10"
check_absent   "sprint: nor the shorter prefix match 'Sprint'" "$ghlog" "--iteration-id ITSHORT"

: > "$FAKE_GH_LOG"
out="$(FAKE_GH_GRAPHQL="$WORK/project.json" bash "$SCRIPTS/squad.sh" sprint 12 "Sprint 1" 2>&1)"
check_contains "sprint: a completed iteration still matches" "$out" "issue #12 is in iteration Sprint 1"

cat > "$WORK/no-iteration.json" <<'STAGED'
{
  "data": {
    "user": {
      "projectV2": {
        "id": "PRJ", "title": "A board", "url": "https://example.invalid",
        "fields": { "nodes": [
          { "id": "F_SPRINT", "name": "Sprint", "options": [
            { "id": "OPT2", "name": "Sprint 2" } ] } ] }
      }
    },
    "repository": { "issue": { "projectItems": { "nodes": [
      { "id": "ITEM", "project": { "id": "PRJ" } } ] } } }
  }
}
STAGED
out="$(FAKE_GH_GRAPHQL="$WORK/no-iteration.json" bash "$SCRIPTS/squad.sh" sprint 12 "Sprint 2" 2>&1)"
check_contains "sprint: a board with no iteration field still works" "$out" "issue #12 is in sprint Sprint 2"
check_contains "sprint: and says the field is missing"               "$out" 'no "Iteration" field'

# --- 7c. housekeeping and the release review --------------------------------

if find "$WORK" -maxdepth 0 -newermt '-1 hour' -printf '' >/dev/null 2>&1; then
# A repository of its own, so that the live run can only ever delete inside it.
HK="$WORK/housekeeping"
mkdir -p "$HK/repo" "$HK/scratch" "$HK/transcripts"
(
  cd "$HK/repo"
  git init -q -b main .
  git config user.name "A Person"
  git config user.email "a@example.invalid"
  printf 'one\n' > file.txt
  git add file.txt
  git commit -q -m "first"
  git checkout -q -b piece-900-merged
  git checkout -q main
) >/dev/null 2>&1

mkdir -p "$HK/scratch/piece-901-gone" "$HK/scratch/piece-902-live" \
         "$HK/scratch/chore-901-gone" "$HK/scratch/review-keep-me" "$HK/scratch/bootstrap"
printf 'x\n' > "$HK/scratch/piece-901-gone/x"
printf 'x\n' > "$HK/scratch/chore-901-gone/x"
printf 'x\n' > "$HK/scratch/review-keep-me/x"
printf 'x\n' > "$HK/scratch/bootstrap/x"
printf 'x\n' > "$HK/scratch/piece-902-live/x"
: > "$HK/scratch/conductor.hold"
touch -d "3 days ago" "$HK/scratch/piece-901-gone/x" "$HK/scratch/piece-901-gone" \
                      "$HK/scratch/chore-901-gone/x" "$HK/scratch/chore-901-gone" \
                      "$HK/scratch/review-keep-me/x" "$HK/scratch/review-keep-me" \
                      "$HK/scratch/bootstrap/x" "$HK/scratch/bootstrap"

# A candidate directory with no branch anywhere, but holding a git worktree of
# its own (not one the outer repo's "git worktree list" knows about, such as a
# nested checkout). Otherwise dead and old enough to be a candidate, it must
# still be kept.
mkdir -p "$HK/scratch/piece-903-nested/.git"
printf 'x\n' > "$HK/scratch/piece-903-nested/x"
touch -d "3 days ago" "$HK/scratch/piece-903-nested/x" "$HK/scratch/piece-903-nested/.git" \
                      "$HK/scratch/piece-903-nested"
printf 'old transcript\n' > "$HK/transcripts/old.jsonl"
touch -d "40 days ago" "$HK/transcripts/old.jsonl"

hk() {
  ( cd "$HK/repo" && bash "$SCRIPTS/housekeeping.sh" \
      --scratch-root "$HK/scratch" --transcripts "$HK/transcripts" \
      --scratch-age-hours 1 --transcript-days 14 "$@" 2>&1 )
}

out="$(hk --dry-run)"
check_contains "housekeeping: a dry run says so"             "$out" "nothing is deleted"
check_contains "housekeeping: a merged branch is a candidate" "$out" "would delete piece-900-merged"
check_contains "housekeeping: a dead scratch directory too"   "$out" "would delete piece-901-gone"
check_contains "housekeeping: and a dead chore directory"     "$out" "would delete chore-901-gone"
check_contains "housekeeping: recent scratch is kept"         "$out" "kept piece-902-live"
check_contains "housekeeping: a directory holding a git worktree is kept" \
  "$out" "kept piece-903-nested: it holds a git worktree"
check_absent   "housekeeping: a review directory is not a candidate" "$out" "delete review-keep-me"
check_absent   "housekeeping: nor is anything else unnamed"   "$out" "delete bootstrap"
check_contains "housekeeping: old transcripts are listed"     "$out" "old.jsonl"
check_contains "housekeeping: and never deleted"              "$out" "never deleted here"
check_equal    "housekeeping: a dry run deletes nothing" \
  "$([ -d "$HK/scratch/piece-901-gone" ] && echo kept || echo gone)" "kept"

out="$(hk)"
check_contains "housekeeping: the live run reports what it freed" "$out" "Freed"
check_equal    "housekeeping: the dead scratch directory is gone" \
  "$([ -d "$HK/scratch/piece-901-gone" ] && echo kept || echo gone)" "gone"
check_equal    "housekeeping: the live one is still there" \
  "$([ -d "$HK/scratch/piece-902-live" ] && echo kept || echo gone)" "kept"
check_equal    "housekeeping: the review directory is untouched" \
  "$([ -d "$HK/scratch/review-keep-me" ] && echo kept || echo gone)" "kept"
check_equal    "housekeeping: the git-worktree directory is untouched" \
  "$([ -d "$HK/scratch/piece-903-nested" ] && echo kept || echo gone)" "kept"
check_equal    "housekeeping: a file in the scratch root is untouched" \
  "$([ -f "$HK/scratch/conductor.hold" ] && echo kept || echo gone)" "kept"
check_equal    "housekeeping: the merged branch is gone" \
  "$(git -C "$HK/repo" show-ref --verify --quiet refs/heads/piece-900-merged && echo kept || echo gone)" "gone"
check_equal    "housekeeping: main is still there" \
  "$(git -C "$HK/repo" show-ref --verify --quiet refs/heads/main && echo kept || echo gone)" "kept"
check_equal    "housekeeping: the transcript is still there" \
  "$([ -f "$HK/transcripts/old.jsonl" ] && echo kept || echo gone)" "kept"
else
  printf 'skip  housekeeping: filesystem age checks require GNU find (Linux runtime target)\n'
  HK="$WORK/housekeeping"
  mkdir -p "$HK"
fi

# The release review, read from a file:// changelog so that nothing goes out.
cat > "$HK/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## 1.0.3

- Added a thing about hooks
- Added a thing about nothing in particular

## 1.0.2

- Fixed something in the sandbox

## 1.0.1

- Added a thing about hooks that is already reviewed
CHANGELOG
printf '# one term per line\nhooks\n\nsandbox\n' > "$HK/watchlist"
printf '1.0.1\n' > "$HK/version"

if command -v curl >/dev/null 2>&1; then
  out="$(bash "$SCRIPTS/changelog-review.sh" --url "file://$HK/CHANGELOG.md" \
        --version-file "$HK/version" --watchlist "$HK/watchlist" 2>/dev/null)"
  check_contains "release review: a newer version is shown"      "$out" "## 1.0.3"
  check_contains "release review: and so is the one below it"    "$out" "## 1.0.2"
  check_absent   "release review: the reviewed version is not"   "$out" "## 1.0.1"
  check_contains "release review: an entry on the watch list"    "$out" "Added a thing about hooks"
  check_absent   "release review: one off it is filtered out"    "$out" "nothing in particular"
  check_contains "release review: it names the version to record" "$out" "1.0.3"

  printf '1.0.3\n' > "$HK/version"
  out="$(bash "$SCRIPTS/changelog-review.sh" --url "file://$HK/CHANGELOG.md" \
        --version-file "$HK/version" --watchlist "$HK/watchlist" 2>/dev/null)"
  check_equal    "release review: nothing newer prints nothing"  "$out" ""

  out="$(bash "$SCRIPTS/changelog-review.sh" --url "file://$HK/CHANGELOG.md" \
        --version-file "$HK/version" --watchlist "$HK/watchlist" --all 2>&1 >/dev/null)"
  check_contains "release review: and says so on standard error" "$out" "nothing newer than 1.0.3"

  out="$(bash "$SCRIPTS/changelog-review.sh" --url "file://$HK/CHANGELOG.md" \
        --version-file "$HK/nope" 2>&1 || true)"
  check_contains "release review: a missing version file is refused" "$out" "Cannot read the version file"
else
  printf 'skip  release review: curl is not installed\n'
fi

# --- 8. the plugin carries no project vocabulary ----------------------------

# The words themselves are not written here, or this file would be the one hit.
# Pass them in:  SQUAD_FORBIDDEN_WORDS='one|two|three' bash scripts/selftest.sh
if [ -n "${SQUAD_FORBIDDEN_WORDS:-}" ]; then
  hits="$(grep -rilE "$SQUAD_FORBIDDEN_WORDS" "$ROOT" --exclude-dir=.git --exclude-dir=results || true)"
  if [ -z "$hits" ]; then
    ok "generic: no project vocabulary appears in the plugin"
  else
    bad "generic: no project vocabulary appears in the plugin" "$hits"
  fi
else
  printf 'skip  generic: set SQUAD_FORBIDDEN_WORDS to check the plugin carries no project vocabulary\n'
fi

# --- 9. the two plugin manifests agree --------------------------------------

native_version="$(jq -r '.version // empty' "$ROOT/.codex-plugin/plugin.json" 2>/dev/null)"
portable_version="$(jq -r '.version // empty' "$ROOT/plugin.json" 2>/dev/null)"
if [ -z "$native_version" ] || [ -z "$portable_version" ]; then
  bad "manifests: both carry a version" "native='$native_version' portable='$portable_version'"
else
  check_equal "manifests: native and portable versions agree" "$native_version" "$portable_version"
fi

REPO_ROOT="$(cd "$ROOT/../../.." && pwd)"
marketplace_path="$(jq -r '.plugins[] | select(.name == "squad") | .source.path // empty' \
  "$REPO_ROOT/.agents/plugins/marketplace.json" 2>/dev/null)"
check_equal "manifests: the marketplace points at the plugin" "$marketplace_path" "./plugins/codex/squad"

# --- the count --------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
