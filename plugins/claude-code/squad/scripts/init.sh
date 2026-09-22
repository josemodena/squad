#!/usr/bin/env bash
# Set a repository up to run on Squad: the labels, the board fields, the
# milestones, the issue templates and the agent entry point.
#
# Everything it creates is named by the settings, so the same command gives two
# different projects their own tracks, owners and decider. It is safe to run
# twice: it creates what is missing and leaves what is there.
set -euo pipefail

SQUAD_TOOL="squad init"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  init.sh check
      Say what exists and what is missing. Changes nothing.

  init.sh create-board "<title>"
      Create an empty project board and print its number. Put that number in
      .claude/squad.local.md as project_number, then run apply.

  init.sh apply [options]
      --milestones "A, B, C"     create these milestones if they are missing
      --milestone-due "A=YYYY-MM-DD,B=YYYY-MM-DD"
      --iteration-start <date>   first iteration start, YYYY-MM-DD
      --iteration-days <n>       iteration length in days (default 7)
      --iteration-count <n>      how many iterations to create (default 8)
      --no-templates             do not write .github/ISSUE_TEMPLATE
      --no-entry-point           do not write the AGENTS.md stub
      --conductor                also install the session conductor
USAGE
  exit 1
}

# --- label and field tables -------------------------------------------------

label_colour() {
  case "$1" in
    type:piece)      printf '1d76db' ;;
    type:sprint)     printf '0e8a16' ;;
    type:retro)      printf '5319e7' ;;
    decision-needed) printf 'd93f0b' ;;
    blocked)         printf 'b60205' ;;
    track:*)         printf 'c5def5' ;;
    owner:*)         printf 'bfd4f2' ;;
    *)               printf 'fbca04' ;;
  esac
}

label_description() {
  case "$1" in
    type:piece)      printf 'One bounded unit of work, one branch, one pull request' ;;
    type:sprint)     printf 'A sprint container, from one weekly reset to the next' ;;
    type:retro)      printf 'What a finished sprint cost and what changes next time' ;;
    decision-needed) printf 'Needs a ruling before the work can go on' ;;
    blocked)         printf 'Waiting on something named in a comment' ;;
    track:*)         printf 'Which track of work this belongs to' ;;
    owner:*)         printf 'Who holds this' ;;
    *)               printf 'Only the Decider can do this' ;;
  esac
}

wanted_labels() {
  local item
  printf '%s\n' 'type:piece' 'type:sprint' 'type:retro' 'type:bug' 'type:enhancement' 'type:documentation' \
    "$SQUAD_DECIDER_LABEL" 'decision-needed' 'blocked'
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf 'track:%s\n' "$(squad_slug "$item")"
  done <<EOL
${SQUAD_TRACKS:-}
EOL
  if [ "$SQUAD_CONTINUATION_MODE" = legacy ]; then
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf 'owner:%s\n' "$(squad_slug "$item")"
  done <<EOL
${SQUAD_OWNERS:-}
EOL
  fi
}

# --- project helpers --------------------------------------------------------

PROJECT_JSON=""
PROJECT_ID=""

owner_root() {
  case "$SQUAD_PROJECT_OWNER_TYPE" in
    organization|org) printf 'organization' ;;
    *) printf 'user' ;;
  esac
}

load_project() {
  [ -z "$PROJECT_JSON" ] || return 0
  squad_require_project
  local root raw
  root="$(owner_root)"
  raw="$(gh api graphql -f owner="$SQUAD_PROJECT_OWNER" -F number="$SQUAD_PROJECT_NUMBER" -f query="
    query(\$owner: String!, \$number: Int!) {
      $root(login: \$owner) {
        projectV2(number: \$number) {
          id title url
          fields(first: 50) { nodes {
            __typename
            ... on ProjectV2FieldCommon { id name }
            ... on ProjectV2SingleSelectField { id name options { id name } }
          } }
        }
      }
    }")"
  PROJECT_JSON="$(printf '%s' "$raw" | jq -c --arg r "$root" '{project: .data[$r].projectV2}')"
  PROJECT_ID="$(printf '%s' "$PROJECT_JSON" | jq -r '.project.id // empty')"
  [ -n "$PROJECT_ID" ] \
    || squad_die "Cannot read project $SQUAD_PROJECT_NUMBER for $SQUAD_PROJECT_OWNER_TYPE $SQUAD_PROJECT_OWNER."
}

field_exists() {
  load_project
  printf '%s' "$PROJECT_JSON" | jq -e --arg n "$1" '.project.fields.nodes[] | select(.name == $n)' >/dev/null 2>&1
}

field_id_of() {
  load_project
  printf '%s' "$PROJECT_JSON" | jq -r --arg n "$1" '.project.fields.nodes[] | select(.name == $n) | .id' | head -1
}

options_literal() {
  # Newline-separated names in, a GraphQL list of option objects out.
  local names="$1" colour="${2:-BLUE}" out="" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    out="$out${out:+, }{name: $(printf '%s' "$name" | jq -R .), color: $colour, description: \"\"}"
  done <<EOL
$names
EOL
  printf '%s' "$out"
}

create_single_select() {
  local name="$1" options="$2" literal
  literal="$(options_literal "$options")"
  [ -n "$literal" ] || { printf 'skipped field %s: the settings list no values for it\n' "$name"; return 0; }
  gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$PROJECT_ID\"
        dataType: SINGLE_SELECT
        name: $(printf '%s' "$name" | jq -R .)
        singleSelectOptions: [ $literal ]
      }) { projectV2Field { ... on ProjectV2SingleSelectField { id name } } }
    }" >/dev/null
  printf 'created field %s\n' "$name"
}

set_single_select_options() {
  local name="$1" options="$2" fid literal
  fid="$(field_id_of "$name")"
  [ -n "$fid" ] || return 1
  literal="$(options_literal "$options")"
  [ -n "$literal" ] || return 0
  gh api graphql -f query="
    mutation {
      updateProjectV2Field(input: {
        fieldId: \"$fid\"
        singleSelectOptions: [ $literal ]
      }) { projectV2Field { ... on ProjectV2SingleSelectField { id } } }
    }" >/dev/null
  printf 'set the options of field %s\n' "$name"
}

create_simple_field() {
  local name="$1" type="$2"
  gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$PROJECT_ID\"
        dataType: $type
        name: $(printf '%s' "$name" | jq -R .)
      }) { projectV2Field { ... on ProjectV2Field { id name } } }
    }" >/dev/null
  printf 'created field %s (%s)\n' "$name" "$type"
}

create_iteration_field() {
  local name="$1" start="$2" days="$3" count="$4"
  local list="" i offset iso title
  i=0
  while [ "$i" -lt "$count" ]; do
    offset=$(( i * days ))
    iso="$(date -u -d "$start + $offset days" '+%Y-%m-%d' 2>/dev/null || true)"
    [ -n "$iso" ] || { printf 'warning: cannot compute iteration dates from %s\n' "$start" >&2; break; }
    title="Sprint $(( i + 1 ))"
    list="$list${list:+, }{startDate: \"$iso\", duration: $days, title: $(printf '%s' "$title" | jq -R .)}"
    i=$(( i + 1 ))
  done
  if gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$PROJECT_ID\"
        dataType: ITERATION
        name: $(printf '%s' "$name" | jq -R .)
        iterationConfiguration: { startDate: \"$start\", duration: $days, iterations: [ $list ] }
      }) { projectV2Field { ... on ProjectV2IterationField { id name } } }
    }" >/dev/null 2>"$TMPERR"; then
    printf 'created field %s (ITERATION, %s iterations of %s days from %s)\n' "$name" "$count" "$days" "$start"
    return 0
  fi
  printf 'warning: the %s field could not be created: %s\n' "$name" "$(tr -d '\n' < "$TMPERR")" >&2
  printf 'warning: add it by hand on the board, or set the iterations there.\n' >&2
  return 0
}

# --- subcommands ------------------------------------------------------------

cmd_check() {
  printf 'settings file: %s\n' "$SQUAD_SETTINGS_FILE"
  printf 'repository:    %s\n\n' "$SQUAD_REPOSITORY"

  printf 'Labels\n'
  local existing name
  existing="$(gh label list --repo "$SQUAD_REPOSITORY" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -qxF "$name"; then
      printf '  present  %s\n' "$name"
    else
      printf '  MISSING  %s\n' "$name"
    fi
  done < <(wanted_labels)

  printf '\nBoard fields\n'
  if [ -z "${SQUAD_PROJECT_NUMBER:-}" ]; then
    printf '  no project_number in the settings, so there is no board yet\n'
  else
    load_project
    for name in "$SQUAD_STATUS_FIELD" Track Owner "$SQUAD_ESTIMATE_FIELD" "$SQUAD_SPRINT_FIELD" Iteration "$SQUAD_NEEDED_BY_FIELD"; do
      if field_exists "$name"; then printf '  present  %s\n' "$name"; else printf '  MISSING  %s\n' "$name"; fi
    done
  fi

  printf '\nIssue templates\n'
  local dir="$PROJECT_ROOT/.github/ISSUE_TEMPLATE"
  for name in piece.md sprint.md retrospective.md action-for-decider.md config.yml; do
    if [ -e "$dir/$name" ]; then printf '  present  %s\n' "$name"; else printf '  MISSING  %s\n' "$name"; fi
  done

  printf '\nAgent entry point\n'
  if [ -e "$PROJECT_ROOT/AGENTS.md" ]; then printf '  present  AGENTS.md\n'; else printf '  MISSING  AGENTS.md\n'; fi
}

cmd_create_board() {
  local title="${1:-}"
  [ -n "$title" ] || squad_die "Usage: init.sh create-board \"<title>\""
  local out number
  out="$(gh project create --owner "$SQUAD_PROJECT_OWNER" --title "$title" --format json)"
  number="$(printf '%s' "$out" | jq -r '.number')"
  [ -n "$number" ] && [ "$number" != "null" ] || squad_die "The board was not created."
  printf 'project board %s created, number %s\n' "$title" "$number"
  printf 'Put this line in %s:\n  project_number: %s\n' "$SQUAD_SETTINGS_FILE" "$number"
}

apply_labels() {
  local existing name
  existing="$(gh label list --repo "$SQUAD_REPOSITORY" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -qxF "$name"; then
      printf 'label %s is already there\n' "$name"
      continue
    fi
    gh label create "$name" --repo "$SQUAD_REPOSITORY" \
      --color "$(label_colour "$name")" --description "$(label_description "$name")" >/dev/null
    printf 'created label %s\n' "$name"
  done < <(wanted_labels)
}

apply_fields() {
  local iteration_start="$1" iteration_days="$2" iteration_count="$3"
  if [ -z "${SQUAD_PROJECT_NUMBER:-}" ]; then
    printf 'no project_number in the settings, so no board fields were touched\n'
    return 0
  fi
  load_project

  if field_exists "$SQUAD_STATUS_FIELD"; then
    set_single_select_options "$SQUAD_STATUS_FIELD" "$SQUAD_STATUSES"
  else
    create_single_select "$SQUAD_STATUS_FIELD" "$SQUAD_STATUSES"
  fi
  PROJECT_JSON=""; load_project

  field_exists "Track" || create_single_select "Track" "${SQUAD_TRACKS:-}"
  PROJECT_JSON=""; load_project
  field_exists "Owner" || create_single_select "Owner" "${SQUAD_OWNERS:-}"
  PROJECT_JSON=""; load_project
  field_exists "$SQUAD_ESTIMATE_FIELD" || create_simple_field "$SQUAD_ESTIMATE_FIELD" NUMBER
  PROJECT_JSON=""; load_project
  field_exists "$SQUAD_SPRINT_FIELD" || create_single_select "$SQUAD_SPRINT_FIELD" "Sprint 1"
  PROJECT_JSON=""; load_project
  field_exists "$SQUAD_NEEDED_BY_FIELD" || create_simple_field "$SQUAD_NEEDED_BY_FIELD" DATE
  PROJECT_JSON=""; load_project
  field_exists "Responsible role" || create_single_select "Responsible role" $'administrator\nproject-manager\narchitect\nengineer\narchitecture-reviewer\nengineering-reviewer'
  PROJECT_JSON=""; load_project
  field_exists "Stage" || create_single_select "Stage" $'planning\narchitecture\narchitecture-review\nengineering\nengineering-review\ndone'
  PROJECT_JSON=""; load_project
  field_exists "Agreement" || create_single_select "Agreement" $'Proposed\nAgreed'
  PROJECT_JSON=""; load_project
  field_exists "Design" || create_single_select "Design" $'Required\nApproved\nExisting'
  PROJECT_JSON=""; load_project
  field_exists "Priority" || create_single_select "Priority" $'P0\nP1\nP2\nP3'
  PROJECT_JSON=""; load_project
  field_exists "Forecast finish" || create_simple_field "Forecast finish" DATE
  PROJECT_JSON=""; load_project
  field_exists "Estimate (hours)" || create_simple_field "Estimate (hours)" NUMBER
  PROJECT_JSON=""; load_project
  field_exists "Iteration" || create_iteration_field "Iteration" "$iteration_start" "$iteration_days" "$iteration_count"
}

apply_milestones() {
  local list="$1" due_list="$2" name due existing
  [ -n "$list" ] || return 0
  existing="$(gh api "repos/$SQUAD_REPOSITORY/milestones?state=all&per_page=100" --jq '.[].title' 2>/dev/null || true)"
  while IFS= read -r name; do
    name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -qxF "$name"; then
      printf 'milestone %s is already there\n' "$name"
      continue
    fi
    due="$(printf '%s' "$due_list" | tr ',' '\n' | awk -F= -v n="$name" '$1 == n { print $2 }' | head -1)"
    if [ -n "$due" ]; then
      gh api "repos/$SQUAD_REPOSITORY/milestones" -f title="$name" -f due_on="${due}T17:00:00Z" >/dev/null
      printf 'created milestone %s, due %s\n' "$name" "$due"
    else
      gh api "repos/$SQUAD_REPOSITORY/milestones" -f title="$name" >/dev/null
      printf 'created milestone %s\n' "$name"
    fi
  done <<EOL
$(printf '%s' "$list" | tr ',' '\n')
EOL
}

apply_templates() {
  local dir="$PROJECT_ROOT/.github/ISSUE_TEMPLATE" src="$SQUAD_ROOT_DIR/templates" f base
  [ -d "$src" ] || squad_die "The plugin's templates directory is missing: $src"
  mkdir -p "$dir"
  for f in "$src"/*; do
    base="$(basename "$f")"
    if [ -e "$dir/$base" ]; then
      printf 'template %s is already there\n' "$base"
      continue
    fi
    local esc_decider esc_decider_label esc_quota_daily esc_quota_cap esc_harness
    esc_decider="$(printf '%s' "${SQUAD_DECIDER:-the Decider}" | sed -e 's/[\/&]/\\&/g')"
    esc_decider_label="$(printf '%s' "$SQUAD_DECIDER_LABEL" | sed -e 's/[\/&]/\\&/g')"
    esc_quota_daily="$(printf '%s' "$SQUAD_QUOTA_DAILY_PERCENT" | sed -e 's/[\/&]/\\&/g')"
    esc_quota_cap="$(printf '%s' "$SQUAD_QUOTA_WEEKLY_CAP_PERCENT" | sed -e 's/[\/&]/\\&/g')"
    esc_harness="$(printf '%s' "${SQUAD_HARNESS_NAME:-the harness}" | sed -e 's/[\/&]/\\&/g')"
    sed -e "s/{{DECIDER}}/$esc_decider/g" \
        -e "s/{{DECIDER_LABEL}}/$esc_decider_label/g" \
        -e "s/{{QUOTA_DAILY}}/$esc_quota_daily/g" \
        -e "s/{{QUOTA_CAP}}/$esc_quota_cap/g" \
        -e "s/{{HARNESS}}/$esc_harness/g" \
        "$f" > "$dir/$base"
    printf 'wrote template %s\n' "$base"
  done
}

apply_entry_point() {
  local file="$PROJECT_ROOT/AGENTS.md"
  if [ -e "$file" ]; then
    printf 'AGENTS.md is already there; it was left alone\n'
    return 0
  fi
  cat > "$file" <<STUB
# Agent entry point

This project runs on Squad, an agile squad of agents. Read the Squad guide
before anything else; it is the README of the installed \`squad\` plugin.

The roles are the User, Administrator, Project Manager, Architect, Engineer,
Architecture Reviewer and Engineering Reviewer. Who plays each one here, which board holds the work, when the sprint
starts and what the project may spend are all in \`.claude/squad.local.md\`.

The rules every session follows without being asked:

- **The board is the state.** Every piece of work is an issue whose body is its
  plan. Start with \`/squad:quota\` and \`/squad:board\`. Move cards as pieces move.
- **Plan before build.** The acceptance test is written before the work starts,
  and the Decider agrees the plan. No build starts on an unagreed plan.
- **One branch per piece.** Every git write goes through the plugin's
  \`gitw.sh\`. Nothing is committed straight to main.
- **Native continuation.** The Administrator dispatches fresh role subagents,
  handles each result immediately and waits on native events when needed.
  Record claims, checkpoints and results through \`squad.sh\`; a final prose
  handover is never the sole recovery record.
- **An agent that has finished is never messaged again.** The next step goes to
  a fresh agent with a written brief.

Write the rest of this file for this project: what it is, where its sources
live, and what an agent must know before touching them.
STUB
  printf 'wrote AGENTS.md\n'
}

cmd_apply() {
  local milestones="" milestone_due="" iteration_start="" iteration_days=7 iteration_count=8
  local do_templates=1 do_entry=1 do_conductor=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --milestones)      milestones="${2:-}"; shift 2 ;;
      --milestone-due)   milestone_due="${2:-}"; shift 2 ;;
      --iteration-start) iteration_start="${2:-}"; shift 2 ;;
      --iteration-days)  iteration_days="${2:-}"; shift 2 ;;
      --iteration-count) iteration_count="${2:-8}"; shift 2 ;;
      --no-templates)    do_templates=0; shift ;;
      --no-entry-point)  do_entry=0; shift ;;
      --conductor)       do_conductor=1; shift ;;
      *) squad_die "Unknown option '$1'." ;;
    esac
  done
  if [ -z "$iteration_start" ]; then
    iteration_start="$(date -u '+%Y-%m-%d')"
  fi

  squad_say "Labels"
  apply_labels
  squad_say "Board fields"
  apply_fields "$iteration_start" "$iteration_days" "$iteration_count"
  squad_say "Milestones"
  if [ -n "$milestones" ]; then apply_milestones "$milestones" "$milestone_due"; else printf 'none asked for\n'; fi
  squad_say "Issue templates"
  if [ "$do_templates" -eq 1 ]; then apply_templates; else printf 'skipped\n'; fi
  squad_say "Agent entry point"
  if [ "$do_entry" -eq 1 ]; then apply_entry_point; else printf 'skipped\n'; fi
  if [ "$do_conductor" -eq 1 ]; then
    squad_say "Conductor"
    bash "$SCRIPT_DIR/install-conductor.sh" || printf 'the conductor was not installed\n'
  fi
  squad_say "Done"
  printf 'The repository is set up. Run /squad:board to see the empty board.\n'
}

# --- dispatch ---------------------------------------------------------------

squad_require_gh
squad_load_settings
PROJECT_ROOT="$(squad_project_dir)"
TMPERR="$(mktemp "${TMPDIR:-/tmp}/squad-init-XXXXXX")"
trap 'rm -f "$TMPERR"' EXIT

case "${1:-}" in
  check)        shift; cmd_check "$@" ;;
  create-board) shift; cmd_create_board "$@" ;;
  apply)        shift; cmd_apply "$@" ;;
  *) usage ;;
esac
