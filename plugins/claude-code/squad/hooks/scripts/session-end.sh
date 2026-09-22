#!/usr/bin/env bash
# SessionEnd: reset the tab to zellij's default name.
#
# session-start.sh renames the tab to the conductor's tab name, which is how
# the conductor knows a session is alive. `undo-rename-tab` resets the tab to
# zellij's default name; it does not restore a chosen name, so a tab renamed
# by hand before the session started is not given that name back. Undoing it
# here is what lets the conductor start the next one. It prints nothing and
# never fails a session.
#
# A session killed hard never reaches this hook, so the name stays. The
# conductor then sees a live session and skips, and the log says so. Rename
# the tab back by hand to let it start again.
set -uo pipefail

[ -n "${ZELLIJ:-}" ] || exit 0
command -v zellij >/dev/null 2>&1 || exit 0

# The same guard as the rename: no settings, no Squad session, nothing to undo.
settings=""
for candidate in "${SQUAD_SETTINGS:-}" "${CLAUDE_PROJECT_DIR:-}/.claude/squad.local.md" "$PWD/.claude/squad.local.md"; do
  [ -n "$candidate" ] || continue
  [ -r "$candidate" ] || continue
  settings="$candidate"
  break
done
[ -n "$settings" ] || exit 0

zellij action undo-rename-tab >/dev/null 2>&1 || true
exit 0
