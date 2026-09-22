#!/usr/bin/env bash
# Optional terminal tab presentation; App Server thread/turn state owns lifecycle.
set -uo pipefail

# A meeting neither renames the Administrator tab nor posts its handover/commits its files.
if [ -n "${SQUAD_MEETING_ID:-}" ]; then
  :
  exit 0
fi

[ -n "${ZELLIJ:-}" ] || exit 0
command -v zellij >/dev/null 2>&1 || exit 0

# The same guard as the rename: no settings, no Squad session, nothing to undo.
settings=""
for candidate in "${SQUAD_SETTINGS:-}" "${CODEX_PROJECT_DIR:-}/.codex/squad.local.md" "$PWD/.codex/squad.local.md"; do
  [ -n "$candidate" ] || continue
  [ -r "$candidate" ] || continue
  settings="$candidate"
  break
done
[ -n "$settings" ] || exit 0

zellij action undo-rename-tab >/dev/null 2>&1 || true
exit 0
