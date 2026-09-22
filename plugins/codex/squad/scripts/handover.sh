#!/usr/bin/env bash
# Post the hand-over comment on the current sprint issue, or print it.
#
# The comment always starts with the marker line <!-- handover --> and always
# carries the same five sections, so the next session can find the latest one
# and read it without being told where to look. It is never edited: a second
# run posts a second comment, and the newest one wins.
set -euo pipefail

SQUAD_TOOL="handover.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

# The marker, the headings and the default texts come from the shared library,
# so the conductor reads exactly what this script writes.
squad_load_settings
MARKER="$SQUAD_HANDOVER_MARKER"

usage() {
  cat >&2 <<'USAGE'
Usage:
  handover.sh [--issue <number>] [--dry-run]
              [--in-flight "<text>"] [--next "<text>"] [--waits "<text>"]
              [--events "<text>"]
  handover.sh --latest [--issue <number>]

  --dry-run   print the comment instead of posting it
  --latest    print the body of the newest hand-over comment on the issue
  --issue     the sprint issue; without it, the current sprint issue is used:
              the open type:sprint issue that is In progress on the board, or
              failing that the one whose window contains now in UTC
USAGE
  exit 1
}

issue_number=""
dry_run=0
latest=0
in_flight=""
next_actions=""
waits=""
events=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)     issue_number="${2:-}"; [ -n "$issue_number" ] || usage; shift 2 ;;
    --dry-run)   dry_run=1; shift ;;
    --latest)    latest=1; shift ;;
    --in-flight) in_flight="${2:-}"; shift 2 ;;
    --next)      next_actions="${2:-}"; shift 2 ;;
    --waits)     waits="${2:-}"; shift 2 ;;
    --events)    events="${2:-}"; shift 2 ;;
    -h|--help)   usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

if [ "$latest" -eq 1 ]; then
  [ -n "$issue_number" ] || issue_number="$(squad_current_sprint_issue)"
  squad_require_gh
  gh issue view "$issue_number" --repo "$SQUAD_REPOSITORY" --json comments \
    --jq "[.comments[] | select(.body | startswith(\"$MARKER\"))] | last | .body // \"\"" \
    | sed -e 's/\r$//'
  exit 0
fi

# --- state of the tree ------------------------------------------------------

tree_section() {
  local root branch head dirty
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$root" ]; then
    printf 'Not inside a git repository, so no tree state was read.\n'
    return 0
  fi
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || branch="unknown"
  head="$(git -C "$root" log --oneline -1 2>/dev/null || echo 'no commits')"
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  printf -- '- Working tree: `%s`\n' "$root"
  printf -- '- Branch: `%s`\n' "$branch"
  printf -- '- Last commit: %s\n' "$head"
  if [ "$dirty" -gt 0 ]; then
    printf -- '- Tree: dirty, %s path(s) unsaved\n' "$dirty"
  else
    printf -- '- Tree: clean\n'
  fi
  local wt
  wt="$(git -C "$root" worktree list 2>/dev/null | sed 's/^/  /' || true)"
  [ -z "$wt" ] || printf -- '- Worktrees:\n```\n%s\n```\n' "$wt"
}

# --- the sprint it belongs to ----------------------------------------------

# The comment names its sprint issue, so a hand-over read anywhere says which
# sprint it came from. A dry run that cannot reach the board still prints.
if [ -z "$issue_number" ]; then
  if [ "$dry_run" -eq 1 ]; then
    issue_number="$(squad_current_sprint_issue 2>/dev/null)" || issue_number=""
  else
    issue_number="$(squad_current_sprint_issue)"
  fi
fi

# The prefix and the time format come from the shared library, because the
# conductor reads this line to tell when the hand-over was written.
written_at="$(date -u "$SQUAD_HANDOVER_TIME_FORMAT")"
if [ -n "$issue_number" ]; then
  header="$(printf '%s%s, sprint issue #%s**' "$SQUAD_HANDOVER_HEADER_PREFIX" "$written_at" "$issue_number")"
else
  header="$(printf '%s%s, sprint issue not resolved**' "$SQUAD_HANDOVER_HEADER_PREFIX" "$written_at")"
fi

body="$(
  printf '%s\n' "$MARKER"
  printf '%s\n\n' "$header"
  printf '## State of the tree\n\n'
  tree_section
  printf '\n## %s\n\n' "$SQUAD_HANDOVER_IN_FLIGHT_HEADING"
  printf '%s\n' "${in_flight:-$SQUAD_HANDOVER_IN_FLIGHT_DEFAULT}"
  printf '\n## %s\n\n' "$SQUAD_HANDOVER_NEXT_HEADING"
  printf '%s\n' "${next_actions:-$SQUAD_HANDOVER_NEXT_DEFAULT}"
  printf '\n## %s\n\n' "$SQUAD_HANDOVER_WAITS_HEADING"
  printf '%s\n' "${waits:-$SQUAD_HANDOVER_WAITS_DEFAULT}"
  printf '\n## %s\n\n' "$SQUAD_HANDOVER_EVENTS_HEADING"
  printf '%s\n' "${events:-$SQUAD_HANDOVER_EVENTS_DEFAULT}"
)"

if [ "$dry_run" -eq 1 ]; then
  printf '%s\n' "$body"
  exit 0
fi

squad_require_gh
gh issue comment "$issue_number" --repo "$SQUAD_REPOSITORY" --body "$body"
