#!/usr/bin/env bash
# Squad per-project settings. Sourced by every Squad script; never run alone.
#
# The settings live in .codex/squad.local.md as YAML front matter. Nothing in
# this plugin knows a project name, a person, a model or a repository: it all
# comes from that one file. The Squad init skill writes it once.

# shellcheck disable=SC2034

SQUAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_SCRIPT_DIR="$(cd "$SQUAD_LIB_DIR/.." && pwd)"
SQUAD_ROOT_DIR="$(cd "$SQUAD_SCRIPT_DIR/.." && pwd)"

squad_die() { printf '%s: %s\n' "${SQUAD_TOOL:-squad}" "$*" >&2; exit 1; }
squad_say() { printf '\n=== %s ===\n' "$*"; }

# A name becomes a label or an option slug: lower case, spaces to hyphens.
squad_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
    | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Where the project lives. A worktree is a project directory of its own, so
# the walk up from the current directory is what makes Squad work in one.
squad_project_dir() {
  local dir
  if [ -n "${SQUAD_PROJECT_DIR:-}" ]; then printf '%s\n' "$SQUAD_PROJECT_DIR"; return 0; fi
  if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR/.codex" ]; then
    printf '%s\n' "$CODEX_PROJECT_DIR"; return 0
  fi
  dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$dir" ]; then printf '%s\n' "$dir"; return 0; fi
  printf '%s\n' "$PWD"
}

squad_find_settings() {
  local dir
  if [ -n "${SQUAD_SETTINGS:-}" ]; then
    [ -r "$SQUAD_SETTINGS" ] || squad_die "SQUAD_SETTINGS names a file that cannot be read: $SQUAD_SETTINGS"
    printf '%s\n' "$SQUAD_SETTINGS"
    return 0
  fi
  for dir in "${SQUAD_PROJECT_DIR:-}" "${CODEX_PROJECT_DIR:-}"; do
    [ -n "$dir" ] || continue
    [ -r "$dir/.codex/squad.local.md" ] || continue
    printf '%s\n' "$dir/.codex/squad.local.md"
    return 0
  done
  dir="$PWD"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -r "$dir/.codex/squad.local.md" ]; then
      printf '%s\n' "$dir/.codex/squad.local.md"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# A settings file may write a path with a leading ~. The front-matter parser
# keeps it literal, because it is not a shell, so expand it here.
squad_expand_home() {
  case "$1" in
    '~')    printf '%s\n' "$HOME" ;;
    '~/'*)  printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

squad_load_settings() {
  local file assignments
  file="$(squad_find_settings)" || squad_die \
    "No Squad settings found. Expected .codex/squad.local.md in the project, or SQUAD_SETTINGS pointing at one. Run the Squad init skill to write it."
  SQUAD_SETTINGS_FILE="$file"
  assignments="$(awk -f "$SQUAD_LIB_DIR/frontmatter.awk" "$file")" \
    || squad_die "Cannot read the front matter of $file"
  eval "$assignments"

  : "${SQUAD_PROJECT_OWNER_TYPE:=user}"
  : "${SQUAD_STATUSES:=Backlog
This sprint
In progress
In review
Blocked
Done}"
  : "${SQUAD_DECIDER_LABEL:=action-for-decider}"
  : "${SQUAD_MIRROR_REMOTE:=}"
  : "${SQUAD_SPRINT_DAY:=Saturday}"
  : "${SQUAD_SPRINT_HOUR_UTC:=17}"
  : "${SQUAD_QUOTA_DAILY_PERCENT:=14}"
  : "${SQUAD_QUOTA_WEEKLY_CAP_PERCENT:=85}"
  : "${SQUAD_QUOTA_COMMAND:=codex-quota}"
  : "${SQUAD_SCRATCH_ROOT:=$HOME/.cache/squad-scratch}"
  : "${SQUAD_SSH_KEY:=}"
  : "${SQUAD_STATUS_FIELD:=Status}"
  : "${SQUAD_SPRINT_FIELD:=Sprint}"
  : "${SQUAD_ITERATION_FIELD:=Iteration}"
  : "${SQUAD_NEEDED_BY_FIELD:=Needed by}"
  : "${SQUAD_ESTIMATE_FIELD:=Estimate (credits %)}"
  : "${SQUAD_CONTINUATION_MODE:=native}"
  : "${SQUAD_QUOTA_MODE:=pacing}"
  : "${SQUAD_ADMINISTRATOR_MODEL:=gpt-6-luna}"
  : "${SQUAD_PROJECT_MANAGER_MODEL:=gpt-6-astra}"
  : "${SQUAD_ARCHITECT_MODEL:=gpt-6-astra}"
  : "${SQUAD_ENGINEER_MODEL:=gpt-6-sol}"
  : "${SQUAD_ARCHITECTURE_REVIEWER_MODEL:=gpt-6-astra}"
  : "${SQUAD_ENGINEERING_REVIEWER_MODEL:=gpt-6-sol}"

  : "${SQUAD_HARNESS_REPOSITORY:=openai/codex}"
  : "${SQUAD_HARNESS_VERSION:=}"
  : "${SQUAD_HARNESS_NAME:=Codex}"

  # Housekeeping and the release review. The paths are the project's, so a
  # project that keeps them elsewhere says so once, here, and the scripts
  # take the same paths as arguments for a one-off run.
  : "${SQUAD_TRANSCRIPTS_DIR:=${CODEX_HOME:-$HOME/.codex}/sessions}"
  : "${SQUAD_MEMORY_STORE:=}"
  : "${SQUAD_HARNESS_CHANGELOG_URL:=https://raw.githubusercontent.com/${SQUAD_HARNESS_REPOSITORY}/main/CHANGELOG.md}"
  : "${SQUAD_HARNESS_VERSION_FILE:=}"
  : "${SQUAD_HARNESS_WATCHLIST:=}"

  # The conductor. The terminal multiplexer session the Administrator lives
  # in, the tab it gets, and the command that is a harness session. The tab is
  # named after the Administrator, so a project that calls the role something
  # else gets a tab of that name without saying so twice.
  : "${SQUAD_CONDUCTOR_SESSION:=codex}"
  : "${SQUAD_CONDUCTOR_TAB:=$(squad_slug "${SQUAD_REPOSITORY:-project}-${SQUAD_CHIEF_OF_STAFF:-lead}")}"
  : "${SQUAD_CONDUCTOR_COMMAND:=codex}"

  local path_setting
  for path_setting in SQUAD_SCRATCH_ROOT SQUAD_SSH_KEY SQUAD_TRANSCRIPTS_DIR \
                      SQUAD_MEMORY_STORE SQUAD_HARNESS_VERSION_FILE SQUAD_HARNESS_WATCHLIST; do
    eval "$path_setting=\"\$(squad_expand_home \"\${$path_setting}\")\""
  done

  [ -n "${SQUAD_REPOSITORY:-}" ] || squad_die "repository is not set in $file"
  case "$SQUAD_REPOSITORY" in
    */*) ;;
    *) squad_die "repository must read owner/name; it reads '$SQUAD_REPOSITORY' in $file" ;;
  esac
  SQUAD_REPO_OWNER="${SQUAD_REPOSITORY%%/*}"
  SQUAD_REPO_NAME="${SQUAD_REPOSITORY##*/}"
  : "${SQUAD_PROJECT_OWNER:=$SQUAD_REPO_OWNER}"
  : "${SQUAD_ORIGIN_REMOTE:=git@github.com:${SQUAD_REPOSITORY}.git}"
}

# Load the installer-owned runtime namespace for direct interactive commands.
# Services receive the same file through systemd's EnvironmentFile directive.
squad_load_conductor_env() {
  [ -z "${SQUAD_CONDUCTOR_STATE:-}" ] || return 0
  local instance env_file
  instance="$(squad_slug "$SQUAD_REPOSITORY")"
  env_file="${XDG_CONFIG_HOME:-$HOME/.config}/squad/$instance.env"
  [ -r "$env_file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

squad_require_gh() {
  command -v gh >/dev/null 2>&1 || squad_die "The GitHub CLI (gh) is not installed."
  command -v jq >/dev/null 2>&1 || squad_die "jq is not installed."
  gh auth status -h github.com >/dev/null 2>&1 \
    || squad_die "The GitHub CLI is not authenticated. Run 'gh auth login -h github.com --web --git-protocol ssh'."
}

squad_require_project() {
  [ -n "${SQUAD_PROJECT_NUMBER:-}" ] \
    || squad_die "project_number is not set in $SQUAD_SETTINGS_FILE, so there is no board to read."
}

# Is $2 one of the newline-separated values in $1?
squad_in_list() {
  local list="$1" needle="$2" item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$item" = "$needle" ] || continue
    return 0
  done <<EOL
$list
EOL
  return 1
}

# Print the canonical entry of a list for a value given either as the entry
# itself or as its slug, so that "First track" and "first-track" both resolve.
squad_resolve_in_list() {
  local list="$1" needle="$2" item needle_slug
  needle_slug="$(squad_slug "$needle")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$item" = "$needle" ] || [ "$(squad_slug "$item")" = "$needle_slug" ]; then
      printf '%s\n' "$item"
      return 0
    fi
  done <<EOL
$list
EOL
  return 1
}

squad_list_inline() {
  printf '%s' "$1" | paste -sd, - | sed 's/,/, /g'
}

# --- the current sprint issue -----------------------------------------------

# Print the number of the sprint issue the squad is working in.
#
# Sprint containers are created ahead of time, so the newest open sprint issue
# is usually a future one and must never be taken for the current sprint. The
# rule, in order:
#
#   1. the open sprint issue whose board Status is "In progress";
#   2. failing that, the one whose window in its body contains now in UTC;
#   3. failing that, an error telling the caller to name it with --issue.
#
# Where more than one issue answers a rule the highest number wins, because
# sprints ascend and a stale card is more likely than a premature one.
squad_current_sprint_issue() {
  squad_require_gh
  local label response nodes count number start finish now begin_ts end_ts windows
  label="${SQUAD_SPRINT_LABEL:-type:sprint}"

  response="$(gh api graphql -f owner="$SQUAD_REPO_OWNER" -f repo="$SQUAD_REPO_NAME" -f query="
    query(\$owner: String!, \$repo: String!) {
      repository(owner: \$owner, name: \$repo) {
        issues(first: 50, states: OPEN, labels: [\"$label\"]) {
          nodes {
            number
            body
            projectItems(first: 10) {
              nodes {
                project { number }
                fieldValues(first: 30) {
                  nodes {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }" 2>/dev/null || true)"

  nodes="$(printf '%s' "$response" \
    | jq -c '[.data.repository.issues.nodes[]?] | sort_by(.number) | reverse' 2>/dev/null || true)"
  count="$(printf '%s' "$nodes" | jq -r 'length' 2>/dev/null || printf '0')"
  [ "${count:-0}" -gt 0 ] 2>/dev/null || squad_die \
    "No open issue labelled $label could be read from $SQUAD_REPOSITORY. Name the sprint issue with --issue."

  # 1. the board.
  number="$(printf '%s' "$nodes" | jq -r \
    --arg field "$SQUAD_STATUS_FIELD" \
    --arg want "In progress" \
    --arg project "${SQUAD_PROJECT_NUMBER:-}" '
      map(select([ .projectItems.nodes[]?
                   | select($project == "" or ((.project.number | tostring) == $project))
                   | .fieldValues.nodes[]?
                   | select(.field.name == $field and .name == $want) ] | length > 0))
      | .[0].number // empty' 2>/dev/null || true)"
  if [ -n "$number" ]; then
    printf '%s\n' "$number"
    return 0
  fi

  # 2. the window written in the body.
  windows="$(printf '%s' "$nodes" | jq -r '
    .[]
    | (.body // "" | gsub("\r"; "")) as $body
    | ($body | capture("Start:[ \t]*(?<v>[^\n]+)") | .v) as $start
    | ($body | capture("End:[ \t]*(?<v>[^\n]+)") | .v) as $end
    | "\(.number)\t\($start)\t\($end)"' 2>/dev/null || true)"
  now="$(date -u +%s)"
  while IFS="$(printf '\t')" read -r number start finish; do
    [ -n "$number" ] || continue
    begin_ts="$(date -u -d "$start" +%s 2>/dev/null || true)"
    end_ts="$(date -u -d "$finish" +%s 2>/dev/null || true)"
    [ -n "$begin_ts" ] && [ -n "$end_ts" ] || continue
    [ "$now" -ge "$begin_ts" ] && [ "$now" -lt "$end_ts" ] || continue
    printf '%s\n' "$number"
    return 0
  done <<EOL
$windows
EOL

  squad_die "No current sprint issue could be identified in $SQUAD_REPOSITORY: no open $label issue has board Status 'In progress', and none has a window containing now. Name it with --issue."
}

# --- the hand-over comment --------------------------------------------------

# One definition of the hand-over's shape, so that the script which writes it
# and the conductor which reads it can never drift apart. The default texts
# matter: a hand-over carrying them says nothing was recorded, and the
# conductor must read that as an empty section rather than as work to do.
SQUAD_HANDOVER_MARKER='<!-- handover -->'
SQUAD_HANDOVER_HEADER_PREFIX='**Hand-over, '
SQUAD_HANDOVER_TIME_FORMAT='+%Y-%m-%d %H:%M UTC'
SQUAD_HANDOVER_IN_FLIGHT_HEADING='Agents in flight'
SQUAD_HANDOVER_NEXT_HEADING='Next actions in order'
SQUAD_HANDOVER_WAITS_HEADING='Waits'
SQUAD_HANDOVER_EVENTS_HEADING='Wake events'
SQUAD_HANDOVER_IN_FLIGHT_DEFAULT='None. No agent is running.'
SQUAD_HANDOVER_NEXT_DEFAULT='None recorded. The next session picks the next piece from the board.'
SQUAD_HANDOVER_WAITS_DEFAULT='None. Nothing is waiting on a clock.'
SQUAD_HANDOVER_EVENTS_DEFAULT='None. No event is ready.'

# Print the time the hand-over says it was written, in seconds since the epoch.
# The header line carries it, written in SQUAD_HANDOVER_TIME_FORMAT, so the
# conductor can tell a hand-over older than the last start it made from one
# written since. Prints nothing when no readable time is there, which the
# caller must treat as "unknown" rather than as "old". Reads standard input.
squad_handover_time() {
  local stamp
  stamp="$(sed -n -e 's/^\*\*Hand-over, \([0-9-]\{10\} [0-9:]\{5\} UTC\).*/\1/p' | head -1)"
  [ -n "$stamp" ] || return 0
  date -u -d "$stamp" +%s 2>/dev/null || true
}

# Print the body of one "## <heading>" section of a hand-over, blank lines
# trimmed from both ends. Reads the hand-over on standard input.
squad_handover_section() {
  local heading="$1"
  awk -v heading="## $heading" '
    { sub(/\r$/, "") }
    $0 == heading { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' | sed -e '/./,$!d' | sed -e ':a' -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
}
