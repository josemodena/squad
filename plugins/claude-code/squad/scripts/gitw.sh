#!/usr/bin/env bash
# Squad git workflow. One branch per piece, nothing straight to main, a pull
# request per piece and an optional mirror push after every merge.
#
# The repository, the expected remote, the mirror and the SSH key all come from
# .claude/squad.local.md. Run it from the project or from a worktree of it.
set -euo pipefail

SQUAD_TOOL="gitw.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

squad_load_settings

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || squad_die "Not inside a git repository."
EXPECTED_REMOTE="$SQUAD_ORIGIN_REMOTE"
MIRROR_REMOTE="${SQUAD_MIRROR_REMOTE:-}"
SSH_KEY="${GITW_SSH_KEY:-${SQUAD_SSH_KEY:-}}"
if [ -n "$SSH_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -i ${SSH_KEY}"
fi
cd "$REPO"

die() { squad_die "$@"; }
say() { squad_say "$@"; }
current_branch() { git rev-parse --abbrev-ref HEAD; }
git_dir() { git rev-parse --git-dir; }

clear_stale_lock() {
  local lock
  lock="$(git_dir)/index.lock"
  [ -e "$lock" ] || return 0
  if [ -n "$(find "$lock" -mmin -1 2>/dev/null)" ]; then
    die "$lock changed in the last minute. A Git process may be running. Stopping."
  fi
  if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
    die "$lock is held by a running process. Stopping."
  fi
  printf 'Clearing stale %s\n' "$lock"
  rm -f -- "$lock"
}

require_identity() {
  [ -n "$(git config --get user.name || true)" ] || die "Git user.name is not configured."
  [ -n "$(git config --get user.email || true)" ] || die "Git user.email is not configured."
}

require_remote_shape() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  [ "$remote" = "$EXPECTED_REMOTE" ] \
    || die "origin is '$remote'; the settings say '$EXPECTED_REMOTE'. Fix the remote, or origin_remote in $SQUAD_SETTINGS_FILE."
}

require_remote_access() {
  git ls-remote --exit-code origin HEAD >/dev/null 2>&1 \
    || die "Access to origin failed. Run 'gitw.sh doctor' for the required checks."
}

require_gh() {
  squad_require_gh
  gh repo view "$SQUAD_REPOSITORY" --json nameWithOwner --jq .nameWithOwner 2>/dev/null \
    | grep -qx "$SQUAD_REPOSITORY" \
    || die "The GitHub CLI cannot read $SQUAD_REPOSITORY."
}

require_non_main() {
  local branch
  branch="$(current_branch)"
  [ "$branch" != "main" ] || die "Refusing to commit directly to main. Run 'start' first."
}

# A merge made while main is checked out in another worktree lands on the
# shared local main, and finish would then push that throwaway commit to both
# remotes. Review worktrees are created detached for this reason.
require_main_free() {
  local here listing path="" main_tree="" main_tree_offender="" offenders="" extra=""
  here="$(git rev-parse --show-toplevel)"
  # Read the list before the loop, so that a failure of this command stops
  # finish instead of leaving the loop with nothing to read and the guard
  # silently passing.
  listing="$(git worktree list --porcelain)"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        # The first entry is the main working tree, which git refuses to remove.
        [ -n "$main_tree" ] || main_tree="$path"
        ;;
      "branch refs/heads/main")
        if [ "$path" = "$here" ]; then
          :
        elif [ "$path" = "$main_tree" ]; then
          main_tree_offender="$path"
          offenders="${offenders}  ${path}"$'\n'
        else
          offenders="${offenders}  ${path}"$'\n'
        fi
        ;;
    esac
  done <<< "$listing"
  [ -n "$offenders" ] || return 0
  if [ -n "$main_tree_offender" ] && [ "$offenders" = "  ${main_tree_offender}"$'\n' ]; then
    die "main is checked out in the main working tree at ${main_tree_offender}. Run finish from there."
  fi
  if [ -n "$main_tree_offender" ]; then
    extra="The main working tree at ${main_tree_offender} cannot be removed; run finish from there instead.
"
  fi
  die "main is checked out in another worktree, so anything merged there lands on the shared local main and the checkout after the merge would fail here. Stopping before the pull request is merged.
${offenders}Run finish from that tree, or remove the worktree with 'git worktree remove <path>', adding --force if it has changes, then run finish again.
${extra}A review worktree is created detached: git worktree add --detach <path> origin/main"
}

# Local main must be exactly origin/main. A commit that exists only here would
# ride out on the post-merge mirror push.
require_main_clean() {
  local ahead
  git show-ref --verify --quiet refs/heads/main || return 0
  git show-ref --verify --quiet refs/remotes/origin/main \
    || die "origin/main is missing locally. Run 'git fetch origin --prune' and try again."
  ahead="$(git rev-list --count origin/main..main)"
  [ "$ahead" -eq 0 ] || die "local main is $ahead commit(s) ahead of origin/main. Stopping before the pull request is merged, because the mirror push would carry them out.
$(git log --oneline origin/main..main | sed 's/^/  /')
Nothing is committed directly to main. Move these commits to a branch, or reset local main to origin/main once you know they are not wanted."
}

branch_name() {
  local kind="${1:-}" first="${2:-}" second="${3:-}"
  case "$kind" in
    piece)
      [ -n "$first" ] && [ -n "$second" ] || die "Usage: gitw.sh start piece <issue-number> <slug>"
      printf 'piece-%s-%s\n' "$first" "$second"
      ;;
    chore|fix)
      [ -n "$first" ] && [ -z "$second" ] || die "Usage: gitw.sh start $kind <slug>"
      printf '%s-%s\n' "$kind" "$first"
      ;;
    [0-9]*)
      [ -n "$first" ] && [ -z "$second" ] || die "Usage: gitw.sh start <issue-number> <slug>"
      printf 'piece-%s-%s\n' "$kind" "$first"
      ;;
    *) die "Branch kind must be piece, chore or fix." ;;
  esac
}

# The mirror push may use an SSH host alias, so it must not inherit the
# /dev/null SSH configuration the origin remote needs.
push_mirror() {
  [ -n "$MIRROR_REMOTE" ] || return 0
  git remote get-url "$MIRROR_REMOTE" >/dev/null 2>&1 \
    || { printf 'warning: no %s remote is configured; the mirror was not pushed.\n' "$MIRROR_REMOTE" >&2; return 0; }
  if env -u GIT_SSH_COMMAND git push "$MIRROR_REMOTE" main; then
    printf 'mirror: pushed main to %s\n' "$MIRROR_REMOTE"
  else
    printf 'warning: the push of main to the %s mirror failed. Run "gitw.sh mirror" once the mirror is reachable.\n' \
      "$MIRROR_REMOTE" >&2
  fi
  return 0
}

cmd_mirror() {
  clear_stale_lock
  [ -n "$MIRROR_REMOTE" ] || die "No mirror_remote is set in $SQUAD_SETTINGS_FILE."
  [ "$(current_branch)" = "main" ] || die "Run 'mirror' from main; it pushes main to the $MIRROR_REMOTE mirror."
  push_mirror
}

warn_dirty_tree() {
  local dirty
  dirty="$(git status --porcelain | wc -l | tr -d ' ')"
  [ "$dirty" -gt 0 ] || return 0
  printf 'warning: %s modified or untracked path(s) are unsaved. Every session ends with a pushed commit, so a previous session may have stopped without saving.\n' \
    "$dirty" >&2
}

cmd_doctor() {
  clear_stale_lock
  require_identity
  [ -z "$SSH_KEY" ] || [ -r "$SSH_KEY" ] || die "The SSH key is missing or unreadable: $SSH_KEY"
  require_remote_shape
  require_remote_access
  require_gh
  say "Squad git workflow ready"
  printf 'settings:   %s\nrepository: %s\nworking tree: %s\nremote: %s\nmirror: %s\nidentity: %s <%s>\n' \
    "$SQUAD_SETTINGS_FILE" "$SQUAD_REPOSITORY" "$REPO" "$EXPECTED_REMOTE" \
    "$([ -n "$MIRROR_REMOTE" ] && git remote get-url "$MIRROR_REMOTE" 2>/dev/null || echo 'not configured')" \
    "$(git config --get user.name)" "$(git config --get user.email)"
  warn_dirty_tree
}

cmd_start() {
  local branch
  branch="$(branch_name "$@")"
  clear_stale_lock
  require_remote_shape
  require_remote_access
  git fetch origin --prune

  if [ -z "$(git status --porcelain)" ]; then
    git checkout main
    git pull --ff-only
  elif [ "$(current_branch)" != "main" ]; then
    die "Working tree is dirty on $(current_branch). Save it before starting another piece."
  else
    say "Carrying the reviewed changes from main onto $branch"
  fi

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch"
    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      git pull --ff-only
    fi
  else
    git checkout -b "$branch"
  fi
  git status --short
}

commit_with_message() {
  local message="$1"
  git commit -q -m "$message" \
    -m "Co-Authored-By: AI coding agent <noreply@users.noreply.github.com>"
}

push_current() {
  local branch
  branch="$(current_branch)"
  if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git push
  else
    git push -u origin "$branch"
  fi
}

cmd_save() {
  local message="${1:-}"
  [ -n "$message" ] || die "Usage: gitw.sh save \"<message>\" -- <paths...>"
  shift
  [ "${1:-}" = "--" ] || die "Scoped paths are required. Use: save \"<message>\" -- <paths...>"
  shift
  [ "$#" -gt 0 ] || die "At least one path is required. Use save-all deliberately for every change."
  require_non_main
  clear_stale_lock
  [ -z "$(git diff --cached --name-only)" ] \
    || die "The index already contains staged changes. Commit or unstage them before a scoped save."
  git add -- "$@"
  [ -n "$(git diff --cached --name-only)" ] || die "The named paths produced no staged change."
  commit_with_message "$message"
  push_current
  git log --oneline -1
}

cmd_save_all() {
  local message="${1:-}"
  [ -n "$message" ] || die "Usage: gitw.sh save-all \"<message>\""
  require_non_main
  clear_stale_lock
  [ -n "$(git status --porcelain)" ] || die "Nothing to commit."
  git add -A
  commit_with_message "$message"
  push_current
  git log --oneline -1
}

cmd_repush() {
  # A branch rebased onto main has rewritten history, so its next push must
  # replace the remote branch. --force-with-lease refuses if somebody else
  # pushed to it meanwhile; main is never a valid target.
  local branch
  require_non_main
  clear_stale_lock
  branch="$(current_branch)"
  [ -z "$(git status --porcelain)" ] || die "Working tree is dirty on $branch. Save before repushing."
  git push --force-with-lease -u origin "$branch"
  git log --oneline -1
}

cmd_submit() {
  local title="${1:-}" issue="${2:-}" branch body
  [ -n "$title" ] || die "Usage: gitw.sh submit \"<pull request title>\" <issue-number>"
  [ -n "$issue" ] || die "An issue number is required. Usage: gitw.sh submit \"<title>\" <issue-number>"
  case "$issue" in
    ''|*[!0-9]*) die "The issue number must be digits only, for example: gitw.sh submit \"<title>\" 42" ;;
  esac
  require_non_main
  clear_stale_lock
  [ -z "$(git status --porcelain)" ] || die "Working tree is dirty. Save before submitting."
  require_remote_shape
  require_remote_access
  require_gh
  branch="$(current_branch)"
  push_current

  if ! gh pr view "$branch" --json number >/dev/null 2>&1; then
    body="$(printf '%s\n\n%s\n\n%s\n' \
      "Closes the work on branch \`$branch\`." \
      "Closes #$issue" \
      "Built with Squad.")"
    gh pr create --base main --head "$branch" --title "$title" --body "$body"
  fi
  if [ -n "${SQUAD_PROJECT_NUMBER:-}" ]; then
    bash "$SCRIPT_DIR/squad.sh" move "$issue" "In review" \
      || printf 'warning: the pull request opened but its card did not move to In review. Run "squad.sh move %s In review".\n' "$issue" >&2
  fi
  gh pr view "$branch" --json number,url,state
}

cmd_finish() {
  local pr="${1:-}" issue="${2:-}" branch labels head_sha comments marker
  [ -n "$pr" ] && [ -n "$issue" ] || die "Usage: gitw.sh finish <pull-request-number> <issue-number>"
  case "$pr" in *[!0-9]*) die "The pull request number must contain digits only." ;; esac
  case "$issue" in *[!0-9]*) die "The issue number must contain digits only." ;; esac
  clear_stale_lock
  [ -z "$(git status --porcelain)" ] || die "Working tree is dirty. Save before finishing."
  require_remote_shape
  require_remote_access
  require_gh
  git fetch origin --prune
  require_main_free
  require_main_clean
  labels="$(gh pr view "$pr" --repo "$SQUAD_REPOSITORY" --json labels --jq '.labels[].name')"
  printf '%s\n' "$labels" | grep -qxF 'review:passed' \
    || die "Pull request #$pr has no review:passed label. A fresh Reviewer must pass it before finish may merge."
  head_sha="$(gh pr view "$pr" --repo "$SQUAD_REPOSITORY" --json headRefOid --jq .headRefOid)"
  [ -n "$head_sha" ] || die "The head commit of pull request #$pr could not be read."
  marker="<!-- squad-review-passed:$head_sha -->"
  comments="$(gh pr view "$pr" --repo "$SQUAD_REPOSITORY" --json comments --jq '.comments[].body')"
  printf '%s\n' "$comments" | grep -qF "$marker" \
    || die "Pull request #$pr has changed since its recorded review, or no review marker exists for $head_sha. Review the current head before finish."
  branch="$(gh pr view "$pr" --repo "$SQUAD_REPOSITORY" --json headRefName --jq .headRefName)"
  gh pr merge "$pr" --repo "$SQUAD_REPOSITORY" --squash --delete-branch --match-head-commit "$head_sha"
  git checkout main
  git pull --ff-only
  git branch -d "$branch" 2>/dev/null || true
  push_mirror
  # The board's built-in "item closed" rule may be off; move the card ourselves.
  if [ -n "${SQUAD_PROJECT_NUMBER:-}" ]; then
    bash "$SCRIPT_DIR/squad.sh" move "$issue" Done \
      || printf 'warning: the issue closed but its card did not move to Done. Run "squad.sh move %s Done".\n' "$issue" >&2
  fi
  git status --short --branch
}

cmd_status() {
  clear_stale_lock
  say "Branch"
  current_branch
  say "Working tree"
  git status --short
  say "Against remote"
  if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git rev-list --left-right --count '@{upstream}...HEAD' \
      | awk '{printf "behind %s, ahead %s\n", $1, $2}'
  else
    printf 'no upstream set\n'
  fi
}

case "${1:-}" in
  doctor) shift; cmd_doctor "$@" ;;
  start) shift; cmd_start "$@" ;;
  save) shift; cmd_save "$@" ;;
  save-all) shift; cmd_save_all "$@" ;;
  repush) shift; cmd_repush "$@" ;;
  submit) shift; cmd_submit "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  mirror) shift; cmd_mirror "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) die "Usage: gitw.sh {doctor | start piece <issue-number> <slug> | start chore|fix <slug> | save \"<msg>\" -- <paths...> | save-all \"<msg>\" | repush | submit \"<title>\" <issue-number> | finish <pull-request-number> <issue-number> | mirror | status}" ;;
esac
