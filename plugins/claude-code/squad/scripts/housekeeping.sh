#!/usr/bin/env bash
# Squad housekeeping. Prune worktrees, delete branches already merged into
# main, clear the scratch directories of branches that no longer exist, list
# old transcripts with their size, and report what disk is left.
#
#   bash scripts/housekeeping.sh --dry-run    what would go, nothing deleted
#   bash scripts/housekeeping.sh              the same, and it goes
#
# Three rules it never breaks:
#
#   1. Nothing uncommitted is deleted. Branches go through "git branch -d",
#      which refuses a branch that is not merged.
#   2. No live worktree is touched, and neither is a scratch directory that
#      holds one.
#   3. Anything written recently is left alone, because a piece in flight
#      writes to its scratch directory and its branch may not exist yet.
#
# Transcripts are listed, never deleted: they are the only record of a session.
set -euo pipefail

SQUAD_TOOL="housekeeping.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

squad_load_settings

DRY_RUN=0
TRANSCRIPT_DAYS=14
SCRATCH_AGE_HOURS=24
SCRATCH_ROOT="$SQUAD_SCRATCH_ROOT"
TRANSCRIPTS_DIR="$SQUAD_TRANSCRIPTS_DIR"
MEMORY_STORE="$SQUAD_MEMORY_STORE"
FREED_MB=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  housekeeping.sh [--dry-run]
                  [--scratch-root <path>]
                  [--scratch-age-hours <n>]
                  [--transcripts <path>]
                  [--transcript-days <n>]
                  [--memory-store <path>]

The paths default to this project's settings in .claude/squad.local.md.
USAGE
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)           DRY_RUN=1; shift ;;
    --scratch-root)      SCRATCH_ROOT="${2:-}"; [ -n "$SCRATCH_ROOT" ] || usage; shift 2 ;;
    --scratch-age-hours) SCRATCH_AGE_HOURS="${2:-}"; [ -n "$SCRATCH_AGE_HOURS" ] || usage; shift 2 ;;
    --transcripts)       TRANSCRIPTS_DIR="${2:-}"; [ -n "$TRANSCRIPTS_DIR" ] || usage; shift 2 ;;
    --transcript-days)   TRANSCRIPT_DAYS="${2:-}"; [ -n "$TRANSCRIPT_DAYS" ] || usage; shift 2 ;;
    --memory-store)      MEMORY_STORE="${2:-}"; [ -n "$MEMORY_STORE" ] || usage; shift 2 ;;
    -h|--help)           usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

case "$TRANSCRIPT_DAYS" in ''|*[!0-9]*) squad_die "--transcript-days must be a whole number." ;; esac
case "$SCRATCH_AGE_HOURS" in ''|*[!0-9]*) squad_die "--scratch-age-hours must be a whole number." ;; esac

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n=== Housekeeping, dry run: nothing is deleted ===\n'
else
  printf '\n=== Housekeeping ===\n'
fi

size_mb() {
  du -sm "$1" 2>/dev/null | awk '{print $1}' || printf '0'
}

# --- 1. worktrees -----------------------------------------------------------

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
WORKTREE_PATHS=""
WORKTREE_BRANCHES=""

if [ -n "$REPO" ]; then
  WORKTREE_PATHS="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{ sub(/^worktree /, ""); print }' || true)"
  WORKTREE_BRANCHES="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^branch /{ sub(/^branch refs\/heads\//, ""); print }' || true)"
fi

squad_say "Worktrees"
if [ -z "$REPO" ]; then
  printf 'not inside a git repository, so worktrees and branches were skipped\n'
else
  printf 'live worktrees:\n'
  printf '%s\n' "$WORKTREE_PATHS" | sed 's/^/  /'
  if [ "$DRY_RUN" -eq 1 ]; then
    git worktree prune --dry-run --verbose 2>&1 | sed 's/^/  would prune: /' || true
  else
    git worktree prune --verbose 2>&1 | sed 's/^/  /' || true
  fi
fi

# --- 2. branches already merged into main -----------------------------------

if [ -n "$REPO" ]; then
  squad_say "Branches merged into main"
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"
  merged="$(git branch --merged main --format='%(refname:short)' 2>/dev/null || true)"
  counted=0
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    [ "$branch" != "main" ] || continue
    [ "$branch" != "$current" ] || continue
    counted=$((counted + 1))
    if squad_in_list "$WORKTREE_BRANCHES" "$branch"; then
      printf '  kept %s: it is checked out in a worktree\n' "$branch"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  would delete %s\n' "$branch"
    else
      git branch -d "$branch" | sed 's/^/  /' \
        || printf '  kept %s: git refused to delete it\n' "$branch"
    fi
  done <<EOL
$merged
EOL
  [ "$counted" -gt 0 ] || printf '  none\n'
fi

# --- 3. scratch directories of branches that no longer exist ----------------

squad_say "Scratch directories under $SCRATCH_ROOT"
if [ ! -d "$SCRATCH_ROOT" ]; then
  printf '  the scratch root does not exist yet\n'
else
  listed=0
  for dir in "$SCRATCH_ROOT"/piece-* "$SCRATCH_ROOT"/chore-* "$SCRATCH_ROOT"/fix-*; do
    [ -d "$dir" ] || continue
    [ ! -L "$dir" ] || continue
    name="$(basename "$dir")"
    listed=$((listed + 1))

    # A local branch of that name.
    if [ -n "$REPO" ] && git show-ref --verify --quiet "refs/heads/$name"; then
      printf '  kept %s: the branch still exists locally\n' "$name"
      continue
    fi
    # A remote branch of that name, as of the last fetch.
    if [ -n "$REPO" ] && [ -n "$(git branch -r --list "*/$name" 2>/dev/null)" ]; then
      printf '  kept %s: the branch still exists on a remote\n' "$name"
      continue
    fi
    # A live worktree inside it, or a worktree it is inside.
    live=0
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      case "$wt" in "$dir"|"$dir"/*) live=1 ;; esac
      case "$dir" in "$wt"/*) live=1 ;; esac
    done <<EOL
$WORKTREE_PATHS
EOL
    if [ "$live" -eq 1 ]; then
      printf '  kept %s: a live worktree is in it\n' "$name"
      continue
    fi
    # Written to recently, so a piece may be in flight in it. A branch is
    # created after the scratch directory as often as before it.
    if [ -n "$(find "$dir" -newermt "-$SCRATCH_AGE_HOURS hours" -print -quit 2>/dev/null)" ]; then
      printf '  kept %s: written to in the last %s hours\n' "$name" "$SCRATCH_AGE_HOURS"
      continue
    fi
    # A worktree can be checked out inside the scratch directory itself, as
    # opposed to the scratch directory being inside a worktree (checked
    # above). Its .git marks that, and it is never a candidate for deletion.
    if [ -n "$(find "$dir" -maxdepth 3 -name .git -print -quit 2>/dev/null)" ]; then
      printf '  kept %s: it holds a git worktree\n' "$name"
      continue
    fi

    mb="$(size_mb "$dir")"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  would delete %s (%s MB)\n' "$name" "$mb"
    else
      rm -rf -- "$dir"
      FREED_MB=$((FREED_MB + mb))
      printf '  deleted %s (%s MB)\n' "$name" "$mb"
    fi
  done
  [ "$listed" -gt 0 ] || printf '  none\n'
  printf '  anything not named piece-, chore- or fix- was left alone\n'
fi

# --- 4. old transcripts, listed and never deleted ---------------------------

squad_say "Transcripts older than $TRANSCRIPT_DAYS days in $TRANSCRIPTS_DIR"
if [ ! -d "$TRANSCRIPTS_DIR" ]; then
  printf '  there is no transcripts directory at that path\n'
else
  listing="$(find "$TRANSCRIPTS_DIR" -type f -mtime "+$TRANSCRIPT_DAYS" -printf '%s\t%p\n' 2>/dev/null || true)"
  if [ -z "$listing" ]; then
    printf '  none\n'
  else
    printf '%s\n' "$listing" | sort -rn | head -20 | awk -F'\t' '
      { printf "  %8.1f MB  %s\n", $1 / 1048576, $2 }'
    printf '%s\n' "$listing" | awk -F'\t' '
      { n += 1; b += $1 }
      END { printf "  %d file(s), %.1f MB in total. Listed only; a transcript is never deleted here.\n", n, b / 1048576 }'
  fi
fi

# --- 5. the memory store and the disk ---------------------------------------

squad_say "Disk"
if [ -n "$MEMORY_STORE" ] && [ -e "$MEMORY_STORE" ]; then
  printf '  memory store %s: %s MB\n' "$MEMORY_STORE" "$(size_mb "$MEMORY_STORE")"
elif [ -n "$MEMORY_STORE" ]; then
  printf '  memory store %s: not present\n' "$MEMORY_STORE"
else
  printf '  no memory store is set in the settings (memory_store)\n'
fi
[ ! -d "$TRANSCRIPTS_DIR" ] || printf '  transcripts %s: %s MB\n' "$TRANSCRIPTS_DIR" "$(size_mb "$TRANSCRIPTS_DIR")"
[ ! -d "$SCRATCH_ROOT" ] || printf '  scratch %s: %s MB\n' "$SCRATCH_ROOT" "$(size_mb "$SCRATCH_ROOT")"
df -h "$HOME" | sed 's/^/  /'

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\nDry run: nothing was deleted. Run it again without --dry-run to free the space.\n'
else
  printf '\nFreed %s MB.\n' "$FREED_MB"
fi
