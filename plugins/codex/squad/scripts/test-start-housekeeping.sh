#!/usr/bin/env bash
# gitw.sh start and housekeeping.sh, proved in a scratch tree. No network: the
# origin is a local bare repository and docker is a fake on PATH that records
# what it was asked to do. Nothing outside the scratch tree is touched.
#
# The same file ships in both plugins; settings are passed with SQUAD_SETTINGS,
# so it does not depend on which harness directory the settings live in.
#
# Prints one line per check and a count. Exit 0 when every check passed.
set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-start-housekeeping-XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'pass  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
check_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to find: $3 in: $2" ;; esac; }
check_absent()   { case "$2" in *"$3"*) bad "$1" "did not expect to find: $3" ;; *) ok "$1" ;; esac; }
check_equal()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', wanted '$3'"; fi; }

# --- fakes ---------------------------------------------------------------------

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
# Fake docker: a build cache and two dangling volumes, one anonymous and one
# named. Every call is recorded.
printf '%s\n' "docker $*" >> "$FAKE_DOCKER_LOG"
case "$*" in
  "info"*) exit 0 ;;
  "system df"*) printf 'Build Cache\t3.1GB\t3.1GB\n'; exit 0 ;;
  *"dangling=true"*"label=com.docker.volume.anonymous"*) printf 'a1b2c3anonymous\n'; exit 0 ;;
  *"dangling=true"*) printf 'a1b2c3anonymous\nnamed-data\n'; exit 0 ;;
  "builder prune"*) printf 'Total reclaimed space: 3.1GB\n'; exit 0 ;;
  "volume rm"*) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/docker"
export FAKE_DOCKER_LOG="$WORK/docker.log"
: > "$FAKE_DOCKER_LOG"
PATH="$WORK/bin:$PATH"

# --- a project with a local origin --------------------------------------------

ORIGIN="$WORK/origin.git"
REPO="$WORK/project"
SCRATCH="$WORK/scratch"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m first
git -C "$REPO" remote add origin "file://$ORIGIN"
git -C "$REPO" push -q -u origin main

cat > "$WORK/settings.md" <<SETTINGS
---
repository: someone/some-repo
project_owner: someone
origin_remote: "file://$ORIGIN"
scratch_root: $SCRATCH
---
SETTINGS
export SQUAD_SETTINGS="$WORK/settings.md"

# --- 1. gitw.sh start makes a worktree and leaves main alone -------------------

out="$(cd "$REPO" && bash "$SCRIPTS/gitw.sh" start piece 7 thing 2>&1)"; rc=$?
check_equal    "start: exits 0"                                "$rc" "0"
check_equal    "start: the main checkout stays on main"        "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main"
check_equal    "start: the worktree is under the scratch root" \
  "$(git -C "$SCRATCH/worktrees/piece-7-thing" rev-parse --abbrev-ref HEAD 2>&1)" "piece-7-thing"
check_contains "start: it prints where the worktree is"        "$out" "$SCRATCH/worktrees/piece-7-thing"
check_equal    "start: the branch starts at origin/main" \
  "$(git -C "$SCRATCH/worktrees/piece-7-thing" rev-parse HEAD 2>&1)" "$(git -C "$REPO" rev-parse origin/main)"

out="$(cd "$REPO" && bash "$SCRIPTS/gitw.sh" start piece 7 thing 2>&1)"; rc=$?
check_equal    "start: a second start of the same piece exits 0" "$rc" "0"
check_contains "start: and reuses the worktree"                  "$out" "already"

printf 'dirty\n' > "$REPO/file.txt"
out="$(cd "$REPO" && bash "$SCRIPTS/gitw.sh" start fix other 2>&1)"; rc=$?
check_equal    "start: a dirty main checkout does not stop it"   "$rc" "0"
check_equal    "start: and the dirty change stays where it was"  "$(cat "$REPO/file.txt")" "dirty"
check_equal    "start: and main is still checked out"            "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main"
git -C "$REPO" checkout -q -- file.txt

# --- 2. housekeeping: docker, a read-only tree, a failed delete -----------------

mkdir -p "$SCRATCH/piece-1-old/gomod/pkg" "$SCRATCH/piece-2-stuck/inner"
printf 'x\n' > "$SCRATCH/piece-1-old/gomod/pkg/file.go"
chmod -R a-w "$SCRATCH/piece-1-old/gomod"
printf 'y\n' > "$SCRATCH/piece-2-stuck/inner/file"
touch -d '3 days ago' "$SCRATCH/piece-1-old" "$SCRATCH/piece-1-old/gomod" \
  "$SCRATCH/piece-1-old/gomod/pkg" "$SCRATCH/piece-1-old/gomod/pkg/file.go" \
  "$SCRATCH/piece-2-stuck" "$SCRATCH/piece-2-stuck/inner" "$SCRATCH/piece-2-stuck/inner/file"

HK=(bash "$SCRIPTS/housekeeping.sh" --transcripts "$WORK/none" --memory-store "$WORK/nomem")

out="$(cd "$REPO" && "${HK[@]}" --dry-run 2>&1)"; rc=$?
check_equal    "housekeeping dry run: exits 0"                    "$rc" "0"
check_contains "housekeeping dry run: lists the docker build cache" "$out" "would prune the docker build cache (3.1GB)"
check_contains "housekeeping dry run: lists the anonymous dangling volume" "$out" "would remove dangling volume a1b2c3anonymous"
check_contains "housekeeping dry run: keeps a named volume"       "$out" "kept volume named-data"
check_contains "housekeeping dry run: lists the read-only tree"   "$out" "would delete piece-1-old"
check_contains "housekeeping dry run: says it is read-only"       "$out" "read-only"
check_absent   "housekeeping dry run: prunes nothing in docker"   "$(cat "$FAKE_DOCKER_LOG")" "prune"
[ -d "$SCRATCH/piece-1-old" ] && ok "housekeeping dry run: the tree is still there" \
  || bad "housekeeping dry run: the tree is still there"

# A fake rm that refuses one directory stands for a delete that fails.
mkdir -p "$WORK/failbin"
cat > "$WORK/failbin/rm" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *piece-2-stuck*) printf 'rm: cannot remove: Operation not permitted\n' >&2; exit 1 ;; esac
exec /bin/rm "$@"
FAKE
chmod +x "$WORK/failbin/rm"
: > "$FAKE_DOCKER_LOG"
out="$(cd "$REPO" && PATH="$WORK/failbin:$PATH" "${HK[@]}" 2>&1)"; rc=$?
check_contains "housekeeping: prunes the docker build cache"      "$(cat "$FAKE_DOCKER_LOG")" "docker builder prune -f"
check_contains "housekeeping: removes the anonymous volume"        "$(cat "$FAKE_DOCKER_LOG")" "docker volume rm a1b2c3anonymous"
check_absent   "housekeeping: never removes a named volume"        "$(cat "$FAKE_DOCKER_LOG")" "named-data"
[ ! -e "$SCRATCH/piece-1-old" ] && ok "housekeeping: the read-only tree is deleted" \
  || bad "housekeeping: the read-only tree is deleted" "$out"
check_contains "housekeeping: a failed delete is reported"        "$out" "could not delete piece-2-stuck"
check_contains "housekeeping: and the run reaches the end"        "$out" "Freed"
check_equal    "housekeeping: a failed delete makes the exit non-zero" "$rc" "1"

# Without docker the run still completes and says so.
out="$(cd "$REPO" && PATH="/usr/bin:/bin" "${HK[@]}" --dry-run --skip-docker 2>&1)"; rc=$?
check_equal    "housekeeping: --skip-docker exits 0"               "$rc" "0"
check_contains "housekeeping: --skip-docker says docker was skipped" "$out" "docker skipped"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
