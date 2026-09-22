#!/usr/bin/env bash
# The two guards that stop finish from pushing a throwaway merge out to the
# remotes, proved in a scratch repository. No real pull request, no real
# remote: a fake ssh serves a local bare repository and a fake gh records the
# calls finish would make. The fake pull request already carries the independent
# review label; this suite tests the local-main guards around the merge.
#
# Every case asserts. The script prints DONE and exits 0 only when all of them
# hold; otherwise it prints FAILED and exits 1.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITW="$PLUGIN_ROOT/scripts/gitw.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/squad-finish-guard-test-XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
FAILURES=0

mkdir -p "$BIN"

cat > "$BIN/ssh" <<'FAKESSH'
#!/usr/bin/env bash
# Fake ssh: run the requested git service against the local bare repository.
cmd="${@: -1}"
prog="${cmd%% *}"
exec "$prog" "$FAKE_SSH_BARE"
FAKESSH
chmod +x "$BIN/ssh"

cat > "$BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
# Fake gh: enough for finish, and it records every call.
printf '%s\n' "gh $*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") printf 'someone/some-repo\n'; exit 0 ;;
  "pr view")
    case "$*" in
      *"--json labels"*) printf 'review:passed\n' ;;
      *"--json headRefOid"*) printf '%s\n' "${FAKE_PR_HEAD:-abc123}" ;;
      *"--json comments"*) printf '<!-- squad-review-passed:%s -->\n' "${FAKE_REVIEW_HEAD:-abc123}" ;;
      *"--json headRefName"*) printf 'piece-999-test\n' ;;
    esac
    exit 0 ;;
  "pr merge") printf 'MERGED\n'; exit 0 ;;
  *) exit 0 ;;
esac
FAKEGH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"

setup() {
  # A fresh repository, its bare origin and a pushed test branch.
  local case_dir="$ROOT/$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir"
  REPO="$case_dir/repo"
  export FAKE_SSH_BARE="$case_dir/origin.git"
  export GH_LOG="$case_dir/gh-calls.log"
  : > "$GH_LOG"
  git init -q --bare -b main "$FAKE_SSH_BARE"
  git init -q -b main "$REPO"
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/squad.local.md" <<'SETTINGS'
---
repository: someone/some-repo
origin_remote: git@github.com:someone/some-repo.git
ssh_key: /dev/null
---
SETTINGS
  git -C "$REPO" config user.name "Test Runner"
  git -C "$REPO" config user.email "test@example.invalid"
  git -C "$REPO" remote add origin git@github.com:someone/some-repo.git
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "Base"
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" checkout -qb piece-999-test
  printf 'change\n' > "$REPO/change.txt"
  git -C "$REPO" add change.txt
  git -C "$REPO" commit -qm "Change"
  git -C "$REPO" push -q -u origin piece-999-test
  CASE_DIR="$case_dir"
}

run_finish() {
  ( cd "$REPO" && bash "$GITW" finish 1 999 ) 2>&1
  printf 'exit: %s\n' "$?"
}

hr() { printf '\n========== %s ==========\n' "$*"; }

check() {
  local what="$1" ok="$2"
  if [ "$ok" -eq 0 ]; then
    printf 'ok: %s\n' "$what"
  else
    printf 'FAIL: %s\n' "$what"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local what="$1" needle="$2" haystack="$3"
  printf '%s\n' "$haystack" | grep -qF -- "$needle"
  check "$what" "$?"
}

assert_line() {
  local what="$1" needle="$2" haystack="$3"
  printf '%s\n' "$haystack" | grep -qxF -- "$needle"
  check "$what" "$?"
}

assert_absent() {
  local what="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
    check "$what" 1
  else
    check "$what" 0
  fi
}

hr "CASE 1: a detached worktree at origin/main does not block finish"
setup case1
git -C "$REPO" worktree add --detach "$CASE_DIR/review-1" origin/main 2>&1 | sed 's/^/  /'
git -C "$REPO" worktree list | sed 's/^/  /'
out="$(run_finish)"
printf '%s\n' "$out"
printf -- '--- gh calls ---\n'
gh_log="$(cat "$GH_LOG")"
printf '%s\n' "$gh_log"
printf -- '--- assertions ---\n'
assert_line "case 1: finish exits 0" "exit: 0" "$out"
assert_contains "case 1: the pull request was merged" "gh pr merge" "$gh_log"

hr "CASE 2: a worktree with main checked out stops finish"
setup case2
git -C "$REPO" worktree add "$CASE_DIR/review-2" main 2>&1 | sed 's/^/  /'
git -C "$REPO" worktree list | sed 's/^/  /'
out="$(run_finish)"
printf '%s\n' "$out"
printf -- '--- gh calls ---\n'
gh_log="$(cat "$GH_LOG")"
printf '%s\n' "$gh_log"
printf -- '--- assertions ---\n'
assert_line "case 2: finish exits 1" "exit: 1" "$out"
assert_absent "case 2: no pull request was merged" "pr merge" "$gh_log"

hr "CASE 3: local main ahead of origin/main stops finish"
setup case3
git -C "$REPO" checkout -q main
printf 'stray\n' > "$REPO/stray.txt"
git -C "$REPO" add stray.txt
git -C "$REPO" commit -qm "Throwaway merge left on main"
git -C "$REPO" checkout -q piece-999-test
out="$(run_finish)"
printf '%s\n' "$out"
printf -- '--- gh calls ---\n'
gh_log="$(cat "$GH_LOG")"
printf '%s\n' "$gh_log"
printf -- '--- assertions ---\n'
assert_line "case 3: finish exits 1" "exit: 1" "$out"
assert_absent "case 3: no pull request was merged" "pr merge" "$gh_log"

# Independent runtime tests exercise detached review preparation with real git.


hr "CASE 5: a push after review stops finish"
setup case5
export FAKE_PR_HEAD=def456
export FAKE_REVIEW_HEAD=abc123
out="$(run_finish)"
printf '%s\n' "$out"
gh_log="$(cat "$GH_LOG")"
printf -- '--- assertions ---\n'
assert_line "case 5: finish exits 1" "exit: 1" "$out"
assert_contains "case 5: the stale review is explained" "changed since its recorded review" "$out"
assert_absent "case 5: no pull request was merged" "pr merge" "$gh_log"
unset FAKE_PR_HEAD FAKE_REVIEW_HEAD

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'All assertions held.\n'
  printf 'DONE\n'
  exit 0
fi
printf '%s assertion(s) failed.\n' "$FAILURES"
printf 'FAILED\n'
exit 1
