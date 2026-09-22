#!/usr/bin/env bash
# One-shot close-out bookkeeping commit on main, for the named exception to the
# branch-per-piece rule. Everything else goes through gitw.sh.
set -euo pipefail

SQUAD_TOOL="closeout.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || squad_die "Not inside a git repository."
MIRROR_REMOTE="${SQUAD_MIRROR_REMOTE:-}"
SSH_KEY="${GITW_SSH_KEY:-${SQUAD_SSH_KEY:-}}"
if [ -n "$SSH_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -i ${SSH_KEY}"
fi
cd "$REPO"

message="${1:-}"
[ -n "$message" ] || squad_die "Usage: closeout.sh \"<commit message>\""
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || squad_die "closeout.sh commits on main only."
[ -n "$(git status --porcelain)" ] || squad_die "Nothing to commit."

git add -A
git commit -q -m "$message" \
  -m "Co-Authored-By: AI coding agent <noreply@users.noreply.github.com>"
git push origin main

# The mirror push may use an SSH host alias, so it must not inherit the
# /dev/null SSH configuration the origin remote needs.
if [ -n "$MIRROR_REMOTE" ]; then
  if git remote get-url "$MIRROR_REMOTE" >/dev/null 2>&1; then
    if env -u GIT_SSH_COMMAND git push "$MIRROR_REMOTE" main; then
      printf 'mirror: pushed main to %s\n' "$MIRROR_REMOTE"
    else
      printf 'warning: the push of main to the %s mirror failed. Run "gitw.sh mirror" once the mirror is reachable.\n' \
        "$MIRROR_REMOTE" >&2
    fi
  else
    printf 'warning: no %s remote is configured; the mirror was not pushed.\n' "$MIRROR_REMOTE" >&2
  fi
fi

git log --oneline -1
