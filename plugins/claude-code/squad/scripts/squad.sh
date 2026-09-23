#!/usr/bin/env bash
# Squad tracker helper over the GitHub CLI.
#
# It creates issues with the project's labels, puts them on the project board,
# sets the board fields, moves them between statuses, assigns them to a sprint,
# sets a needed-by date, prints the board and posts a quota reading on a sprint
# issue. Every project-specific value comes from .claude/squad.local.md.
set -euo pipefail

SQUAD_TOOL="squad.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

# Durable execution and typed tracker operations share one implementation.
case "${1:-}" in
  context|memory|inbox|pm-claim|ready|next|recover|metrics|wake|state|models|policy|pause|resume|observe|field|dependency|claim|repair-claim|bind|checkpoint|complete|handoff|ack|retry|external|settle|comment|issue-read|pr-read|issue-create|run|review-prepare|review-record)
    exec bash "$SCRIPT_DIR/runtime.sh" "$@" ;;
esac


usage() {
  cat >&2 <<'USAGE'
Usage:
  squad.sh issue "<title>" --track <track> --owner <owner>
                           [--estimate <percent>]
                           [--needed-by <YYYY-MM-DD>]
                           [--body-file <path> | --body "<text>"]
                           [--label <extra label>]...
  squad.sh move <issue-number> <status>
  squad.sh sprint <issue-number> "<sprint name>"
  squad.sh needed-by <issue-number> <YYYY-MM-DD>
  squad.sh board [--sprint "<name>"]
  squad.sh sprint-issue
  squad.sh quota-note <sprint-issue-number>
  squad.sh settings

The tracks, the owners and the statuses come from .claude/squad.local.md.
Run "squad.sh settings" to see the ones this project uses.
USAGE
  exit 1
}

# --- project metadata -------------------------------------------------------

# Both are filled by load_project. They must be loaded in the command's own
# shell, because an assignment inside a $( ) substitution never reaches it.
PROJECT_JSON=""
PROJECT_ID=""

owner_root() {
  case "$SQUAD_PROJECT_OWNER_TYPE" in
    organization|org) printf 'organization' ;;
    user) printf 'user' ;;
    *) squad_die "project_owner_type must be user or organization; it reads '$SQUAD_PROJECT_OWNER_TYPE'." ;;
  esac
}

load_project() {
  [ -z "$PROJECT_JSON" ] || return 0
  squad_require_project
  local root
  root="$(owner_root)"
  PROJECT_JSON="$(gh api graphql \
    -f owner="$SQUAD_PROJECT_OWNER" -F number="$SQUAD_PROJECT_NUMBER" \
    -f query="
      query(\$owner: String!, \$number: Int!) {
        $root(login: \$owner) {
          projectV2(number: \$number) {
            id
            title
            url
            fields(first: 50) {
              nodes {
                ... on ProjectV2FieldCommon { id name }
                ... on ProjectV2SingleSelectField { id name options { id name } }
                ... on ProjectV2IterationField {
                  id name
                  configuration {
                    iterations { id title startDate duration }
                    completedIterations { id title startDate duration }
                  }
                }
              }
            }
          }
        }
      }")"
  PROJECT_JSON="$(printf '%s' "$PROJECT_JSON" | jq -c --arg r "$root" '{data: {project: .data[$r].projectV2}}')"
  local id
  id="$(printf '%s' "$PROJECT_JSON" | jq -r '.data.project.id // empty')"
  [ -n "$id" ] || squad_die "Cannot read project $SQUAD_PROJECT_NUMBER for $SQUAD_PROJECT_OWNER_TYPE $SQUAD_PROJECT_OWNER."
  PROJECT_ID="$id"
}

field_id() {
  local name="$1" id
  load_project
  id="$(printf '%s' "$PROJECT_JSON" \
    | jq -r --arg n "$name" '.data.project.fields.nodes[] | select(.name == $n) | .id' | head -1)"
  [ -n "$id" ] || squad_die "The project has no field named '$name'. Run /squad:init to create the fields."
  printf '%s\n' "$id"
}

has_field() {
  local name="$1"
  load_project
  printf '%s' "$PROJECT_JSON" \
    | jq -e --arg n "$name" '[.data.project.fields.nodes[] | select(.name == $n)] | length > 0' >/dev/null
}

# The iteration on an iteration field that carries this sprint's name.
#
# A sprint's single-select option often says more than its iteration does:
# "Sprint 2 (19 to 26 Sep 2026)" against a plain "Sprint 2". So an exact title
# wins, and a title that the name begins with, followed by a space, comes next.
# The space matters: without it "Sprint 1" would claim "Sprint 10". Among
# several prefix matches the longest title wins, because it is the more
# specific one: "Sprint 2" over "Sprint" for a name of "Sprint 2 (...)".
iteration_id() {
  local field="$1" name="$2"
  load_project
  printf '%s' "$PROJECT_JSON" | jq -r --arg f "$field" --arg n "$name" '
    [ .data.project.fields.nodes[]
      | select(.name == $f)
      | ((.configuration.iterations // []) + (.configuration.completedIterations // []))[] ] as $its
    | ( [ $its[] | select(.title == $n) ]
        + ( [ $its[] | select(. as $it | $n | startswith($it.title + " ")) ]
            | sort_by(.title | length) | reverse ) )
    | if length == 0 then empty else "\(.[0].id)\t\(.[0].title)" end'
}

option_id() {
  local field="$1" option="$2" id
  load_project
  id="$(printf '%s' "$PROJECT_JSON" \
    | jq -r --arg f "$field" --arg o "$option" \
      '.data.project.fields.nodes[] | select(.name == $f) | .options[]? | select(.name == $o) | .id' | head -1)"
  printf '%s\n' "$id"
}

BOARD_BACKED_UP=0
backup_board() {
  [ "$BOARD_BACKED_UP" = 1 ] && return 0
  bash "$SCRIPT_DIR/board-backup.sh" guard --writes 10 >&2
  BOARD_BACKED_UP=1
}

set_single_select() {
  local item_id="$1" field="$2" option="$3" fid oid
  fid="$(field_id "$field")"
  oid="$(option_id "$field" "$option")"
  [ -n "$oid" ] || squad_die "The field '$field' has no option '$option'."
  backup_board
  gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
    --field-id "$fid" --single-select-option-id "$oid" >/dev/null
}

set_number() {
  local item_id="$1" field="$2" value="$3" fid
  fid="$(field_id "$field")"
  backup_board
  gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
    --field-id "$fid" --number "$value" >/dev/null
}

set_date() {
  local item_id="$1" field="$2" value="$3" fid
  fid="$(field_id "$field")"
  backup_board
  gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
    --field-id "$fid" --date "$value" >/dev/null
}

set_iteration() {
  local item_id="$1" field="$2" iteration_id="$3" fid
  fid="$(field_id "$field")"
  backup_board
  gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
    --field-id "$fid" --iteration-id "$iteration_id" >/dev/null
}

item_id_for_issue() {
  local number="$1" id
  load_project
  id="$(gh api graphql \
    -f owner="$SQUAD_REPO_OWNER" -f repo="$SQUAD_REPO_NAME" -F number="$number" \
    -f query='
      query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          issue(number: $number) {
            projectItems(first: 20) { nodes { id project { id } } }
          }
        }
      }' \
    | jq -r --arg p "$PROJECT_ID" \
      '.data.repository.issue.projectItems.nodes[]? | select(.project.id == $p) | .id' | head -1)"
  [ -n "$id" ] || squad_die "Issue #$number is not on the project board."
  printf '%s\n' "$id"
}

require_issue_number() {
  case "${1:-}" in
    ''|*[!0-9]*) squad_die "The issue number must be digits only." ;;
  esac
}

require_date() {
  case "${1:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) squad_die "The date must read YYYY-MM-DD; it reads '${1:-}'." ;;
  esac
}

# --- subcommands ------------------------------------------------------------

cmd_settings() {
  printf 'settings file: %s\n' "$SQUAD_SETTINGS_FILE"
  printf 'repository:    %s\n' "$SQUAD_REPOSITORY"
  printf 'board:         %s %s, project %s\n' "$SQUAD_PROJECT_OWNER_TYPE" "$SQUAD_PROJECT_OWNER" "${SQUAD_PROJECT_NUMBER:-none}"
  printf 'mirror remote: %s\n' "${SQUAD_MIRROR_REMOTE:-none}"
  printf 'sprint clock:  %s %s:00 UTC to %s %s:00 UTC\n' \
    "$SQUAD_SPRINT_DAY" "$SQUAD_SPRINT_HOUR_UTC" "$SQUAD_SPRINT_DAY" "$SQUAD_SPRINT_HOUR_UTC"
  printf 'quota:         %s%% a day, %s%% a week\n' "$SQUAD_QUOTA_DAILY_PERCENT" "$SQUAD_QUOTA_WEEKLY_CAP_PERCENT"
  printf 'tracks:        %s\n' "$(squad_list_inline "${SQUAD_TRACKS:-}")"
  printf 'owners:        %s\n' "$(squad_list_inline "${SQUAD_OWNERS:-}")"
  printf 'statuses:      %s\n' "$(squad_list_inline "$SQUAD_STATUSES")"
  printf 'decider:       %s (label %s)\n' "${SQUAD_DECIDER:-not set}" "$SQUAD_DECIDER_LABEL"
  printf 'role models: %s\n' "$(bash "$SCRIPT_DIR/runtime.sh" models)"
  printf 'effective policy: %s\n' "$(bash "$SCRIPT_DIR/runtime.sh" policy)"
  printf 'conductor:     tab %s in session %s, running %s\n' \
    "$SQUAD_CONDUCTOR_TAB" "$SQUAD_CONDUCTOR_SESSION" "$SQUAD_CONDUCTOR_COMMAND"
}

cmd_issue() {
  local title="${1:-}"
  [ -n "$title" ] || usage
  shift || true

  local track="" owner="" estimate="" needed_by="" body="" body_file=""
  local -a extra_labels=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --track)     track="${2:-}"; [ -n "$track" ] || usage; shift 2 ;;
      --owner)     owner="${2:-}"; [ -n "$owner" ] || usage; shift 2 ;;
      --estimate)  estimate="${2:-}"; [ -n "$estimate" ] || usage; shift 2 ;;
      --needed-by) needed_by="${2:-}"; [ -n "$needed_by" ] || usage; shift 2 ;;
      --body)      body="${2:-}"; [ -n "$body" ] || usage; shift 2 ;;
      --body-file) body_file="${2:-}"; [ -n "$body_file" ] || usage; shift 2 ;;
      --label)     [ -n "${2:-}" ] || usage; extra_labels+=("$2"); shift 2 ;;
      *) squad_die "Unknown option '$1'." ;;
    esac
  done

  [ -n "$track" ] || squad_die "--track is required. This project's tracks: $(squad_list_inline "${SQUAD_TRACKS:-}")"
  track="$(squad_resolve_in_list "${SQUAD_TRACKS:-}" "$track")" \
    || squad_die "--track must be one of: $(squad_list_inline "${SQUAD_TRACKS:-}")"
  [ -n "$owner" ] || squad_die "--owner is required. This project's owners: $(squad_list_inline "${SQUAD_OWNERS:-}")"
  owner="$(squad_resolve_in_list "${SQUAD_OWNERS:-}" "$owner")" \
    || squad_die "--owner must be one of: $(squad_list_inline "${SQUAD_OWNERS:-}")"
  if [ -n "$estimate" ]; then
    case "$estimate" in
      ''|*[!0-9.]*) squad_die "--estimate must be a number, for example 5 or 2.5." ;;
    esac
  fi
  [ -z "$needed_by" ] || require_date "$needed_by"
  [ -z "$body" ] || [ -z "$body_file" ] || squad_die "Use either --body or --body-file, not both."
  [ -z "$body_file" ] || [ -r "$body_file" ] || squad_die "Cannot read the body file: $body_file"

  local -a args=(issue create --repo "$SQUAD_REPOSITORY" --title "$title"
                 --label "track:$(squad_slug "$track")")
  [ "$SQUAD_CONTINUATION_MODE" != legacy ] || args+=(--label "owner:$(squad_slug "$owner")")
  local l
  for l in ${extra_labels+"${extra_labels[@]}"}; do
    args+=(--label "$l")
  done
  if [ -n "$body_file" ]; then
    args+=(--body-file "$body_file")
  else
    args+=(--body "${body:-To be written.}")
  fi

  local url number item_id
  url="$(gh "${args[@]}")"
  url="$(printf '%s\n' "$url" | tr -d '\r' | grep -o 'https://[^[:space:]]*/issues/[0-9]*' | tail -1)"
  [ -n "$url" ] || squad_die "The issue was not created, or its URL could not be read."
  number="${url##*/}"

  load_project
  backup_board
  item_id="$(gh project item-add "$SQUAD_PROJECT_NUMBER" --owner "$SQUAD_PROJECT_OWNER" --url "$url" --format json \
    | jq -r '.id')"
  [ -n "$item_id" ] && [ "$item_id" != "null" ] || squad_die "The issue was created but could not be added to the board."

  set_single_select "$item_id" "Track" "$track"
  set_single_select "$item_id" "Owner" "$owner"
  set_single_select "$item_id" "$SQUAD_STATUS_FIELD" "Backlog"
  [ -z "$estimate" ] || set_number "$item_id" "$SQUAD_ESTIMATE_FIELD" "$estimate"
  [ -z "$needed_by" ] || set_date "$item_id" "$SQUAD_NEEDED_BY_FIELD" "$needed_by"

  printf 'issue #%s\n%s\n' "$number" "$url"
}

cmd_move() {
  local number="${1:-}" status="${2:-}"
  [ -n "$number" ] && [ -n "$status" ] || usage
  require_issue_number "$number"
  status="$(squad_resolve_in_list "$SQUAD_STATUSES" "$status")" \
    || squad_die "Status must be one of: $(squad_list_inline "$SQUAD_STATUSES")"
  load_project
  local item_id
  item_id="$(item_id_for_issue "$number")"
  set_single_select "$item_id" "$SQUAD_STATUS_FIELD" "$status"
  printf 'issue #%s is now %s\n' "$number" "$status"
}

ensure_option() {
  local field="$1" name="$2" fid existing options_json literal
  fid="$(field_id "$field")"
  existing="$(option_id "$field" "$name")"
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return 0
  fi
  # The typed helper snapshots first, preserves option IDs and verifies values.
  bash "$SCRIPT_DIR/board-backup.sh" options "$field" --names "$name" --apply >&2

  PROJECT_JSON=""
  load_project
  existing="$(option_id "$field" "$name")"
  [ -n "$existing" ] || squad_die "Could not create the $field option '$name'."
  printf '%s\n' "$existing"
}

cmd_sprint() {
  local number="${1:-}" name="${2:-}"
  [ -n "$number" ] && [ -n "$name" ] || usage
  require_issue_number "$number"
  load_project
  local item_id
  item_id="$(item_id_for_issue "$number")"
  ensure_option "$SQUAD_SPRINT_FIELD" "$name" >/dev/null
  set_single_select "$item_id" "$SQUAD_SPRINT_FIELD" "$name"
  printf 'issue #%s is in sprint %s\n' "$number" "$name"

  # The board carries the sprint twice: a single-select the scripts read and
  # an iteration the built-in burn-up and roadmap views read. One command sets
  # both, so the two can never disagree.
  if ! has_field "$SQUAD_ITERATION_FIELD"; then
    printf 'note: the board has no "%s" field, so only %s was set. Run /squad:init to create it.\n' \
      "$SQUAD_ITERATION_FIELD" "$SQUAD_SPRINT_FIELD" >&2
    return 0
  fi
  local iteration iteration_title
  iteration="$(iteration_id "$SQUAD_ITERATION_FIELD" "$name")"
  iteration_title="${iteration#*	}"
  iteration="${iteration%%	*}"
  if [ -z "$iteration" ]; then
    printf 'note: no iteration on the "%s" field is named "%s" or begins it, so the iteration was left alone.\n' \
      "$SQUAD_ITERATION_FIELD" "$name" >&2
    return 0
  fi
  set_iteration "$item_id" "$SQUAD_ITERATION_FIELD" "$iteration"
  printf 'issue #%s is in iteration %s\n' "$number" "$iteration_title"
}

cmd_needed_by() {
  local number="${1:-}" date="${2:-}"
  [ -n "$number" ] && [ -n "$date" ] || usage
  require_issue_number "$number"
  require_date "$date"
  load_project
  local item_id
  item_id="$(item_id_for_issue "$number")"
  set_date "$item_id" "$SQUAD_NEEDED_BY_FIELD" "$date"
  printf 'issue #%s is needed by %s\n' "$number" "$date"
}

cmd_board() {
  local sprint_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sprint) sprint_filter="${2:-}"; [ -n "$sprint_filter" ] || usage; shift 2 ;;
      *) squad_die "Unknown option '$1'." ;;
    esac
  done
  load_project
  local root
  root="$(owner_root)"

  local items cursor="" page has_next
  items="[]"
  while :; do
    if [ -z "$cursor" ]; then
      page="$(gh api graphql -f owner="$SQUAD_PROJECT_OWNER" -F number="$SQUAD_PROJECT_NUMBER" -f query="
        query(\$owner: String!, \$number: Int!) {
          $root(login: \$owner) { projectV2(number: \$number) { items(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              content { ... on Issue { number title url state } }
              fieldValues(first: 30) { nodes {
                ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
              } }
            }
          } } }
        }")"
    else
      page="$(gh api graphql -f owner="$SQUAD_PROJECT_OWNER" -F number="$SQUAD_PROJECT_NUMBER" -f cursor="$cursor" -f query="
        query(\$owner: String!, \$number: Int!, \$cursor: String!) {
          $root(login: \$owner) { projectV2(number: \$number) { items(first: 100, after: \$cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              content { ... on Issue { number title url state } }
              fieldValues(first: 30) { nodes {
                ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
              } }
            }
          } } }
        }")"
    fi
    items="$(jq -n --argjson a "$items" \
      --argjson b "$(printf '%s' "$page" | jq -c --arg r "$root" '.data[$r].projectV2.items.nodes')" '$a + $b')"
    has_next="$(printf '%s' "$page" | jq -r --arg r "$root" '.data[$r].projectV2.items.pageInfo.hasNextPage')"
    [ "$has_next" = "true" ] || break
    cursor="$(printf '%s' "$page" | jq -r --arg r "$root" '.data[$r].projectV2.items.pageInfo.endCursor')"
  done

  local statuses_json
  statuses_json="$(printf '%s\n' "$SQUAD_STATUSES" | jq -R . | jq -sc 'map(select(. != "")) + ["No status"]')"

  local printed
  printed="$(printf '%s\n' "$items" | jq -r \
    --arg sprint "$sprint_filter" \
    --arg statusfield "$SQUAD_STATUS_FIELD" \
    --arg sprintfield "$SQUAD_SPRINT_FIELD" \
    --arg estimatefield "$SQUAD_ESTIMATE_FIELD" \
    --arg neededbyfield "$SQUAD_NEEDED_BY_FIELD" \
    --argjson statuses "$statuses_json" '
    def field($n):
      (.fieldValues.nodes[]? | select(.field.name == $n)
        | (.name // .date // (.number | tostring))) // "";
    map(select(.content != null))
    | map({
        number: .content.number,
        title:  .content.title,
        status: (field($statusfield)   | if . == "" then "No status" else . end),
        owner:  (field("Owner")        | if . == "" then "-" else . end),
        est:    (field($estimatefield) | if . == "" then "-" else . end),
        needed: (field($neededbyfield) | if . == "" then "-" else . end),
        sprint: (field($sprintfield)   | if . == "" then "-" else . end)
      })
    | if $sprint == "" then . else map(select(.sprint == $sprint)) end
    | . as $all
    | $statuses
    | map(. as $s | {status: $s, rows: ($all | map(select(.status == $s)) | sort_by(.number))})
    | map(select(.rows | length > 0))
    | map(
        "\n== \(.status) (\(.rows | length)) ==",
        (.rows[] | "  #\(.number)  \(.title)\n        owner \(.owner) | estimate \(.est) | sprint \(.sprint) | needed by \(.needed)")
      )
    | flatten | .[]')"

  if [ -z "$printed" ]; then
    if [ -n "$sprint_filter" ]; then
      printf 'The board has no items in sprint %s.\n' "$sprint_filter"
    else
      printf 'The board is empty.\n'
    fi
  else
    printf '%s\n' "$printed"
  fi
}

# The number of the sprint the squad is working in, for anything that has to
# land on the running sprint rather than on the newest container.
cmd_sprint_issue() {
  [ "$#" -eq 0 ] || usage
  squad_current_sprint_issue
}

cmd_quota_note() {
  local number="${1:-}"
  [ -n "$number" ] || usage
  require_issue_number "$number"

  local quota_bin usage_bin
  quota_bin="$(command -v "$SQUAD_QUOTA_COMMAND" || true)"
  usage_bin="$(command -v "$SQUAD_USAGE_COMMAND" || true)"
  [ -n "$quota_bin" ] || squad_die "The quota command '$SQUAD_QUOTA_COMMAND' is not on PATH."
  [ -n "$usage_bin" ] || squad_die "The usage command '$SQUAD_USAGE_COMMAND' is not on PATH."

  local stamp quota_out usage_out body
  stamp="$(date -u '+%Y-%m-%d %H:%M UTC')"
  quota_out="$("$quota_bin" 2>&1 || true)"
  usage_out="$("$usage_bin" --summary 2>&1 || true)"

  body="$(printf '**Quota reading, %s**\n\n`%s`\n\n```\n%s\n```\n\n`%s --summary`\n\n```\n%s\n```\n' \
    "$stamp" "$SQUAD_QUOTA_COMMAND" "$quota_out" "$SQUAD_USAGE_COMMAND" "$usage_out")"

  gh issue comment "$number" --repo "$SQUAD_REPOSITORY" --body "$body"
}

# --- dispatch ---------------------------------------------------------------

squad_require_gh
squad_load_settings

case "${1:-}" in
  issue)      shift; cmd_issue "$@" ;;
  move)       shift; cmd_move "$@" ;;
  sprint)     shift; cmd_sprint "$@" ;;
  needed-by)  shift; cmd_needed_by "$@" ;;
  board)      shift; cmd_board "$@" ;;
  sprint-issue) shift; cmd_sprint_issue "$@" ;;
  quota-note) shift; cmd_quota_note "$@" ;;
  settings)   shift; cmd_settings "$@" ;;
  *) usage ;;
esac
