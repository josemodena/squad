#!/usr/bin/env bash
# Optional terminal tab presentation; App Server thread/turn state owns lifecycle.
set -uo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPTS="$PLUGIN_ROOT/scripts"

printf 'Squad session start\n\n'

# --- the quota --------------------------------------------------------------

quota_line=""
if [ -x "$SCRIPTS/codex-quota" ]; then
  quota_line="$("$SCRIPTS/codex-quota" 2>&1 || true)"
elif command -v codex-quota >/dev/null 2>&1; then
  quota_line="$(codex-quota 2>&1 || true)"
fi
quota_line="$(printf '%s' "$quota_line" | head -1)"
if [ -z "$quota_line" ]; then
  quota_line="unknown: no quota command could be run"
fi
printf 'quota: %s\n\n' "$quota_line"

# --- the settings ----------------------------------------------------------

settings=""
for candidate in "${SQUAD_SETTINGS:-}" "${CODEX_PROJECT_DIR:-}/.codex/squad.local.md" "$PWD/.codex/squad.local.md"; do
  [ -n "$candidate" ] || continue
  [ -r "$candidate" ] || continue
  settings="$candidate"
  break
done

if [ -z "$settings" ]; then
  printf 'board: this project has no .codex/squad.local.md yet. Run the Squad init skill to set it up.\n'
  exit 0
fi

# --- the tab --------------------------------------------------------------

# Only inside a multiplexer, and only when the settings say what the tab is
# called. Any failure is ignored: a tab that cannot be renamed is a worse
# session, not a broken one. session-end.sh resets the tab to zellij's
# default name.
if [ -n "${ZELLIJ:-}" ] && command -v zellij >/dev/null 2>&1; then
  tab="$(SQUAD_SETTINGS="$settings" bash -c \
    '. "$1/lib/settings.sh"; squad_load_settings; printf "%s\n" "$SQUAD_CONDUCTOR_TAB"' \
    _ "$SCRIPTS" 2>/dev/null || true)"
  if [ -n "$tab" ]; then
    zellij action rename-tab "$tab" >/dev/null 2>&1 || true
    printf 'tab: %s\n\n' "$tab"
  fi
fi

# --- the board ------------------------------------------------------------

board="$(bash "$SCRIPTS/squad.sh" board 2>&1 || true)"
if [ -z "$board" ]; then
  printf 'board: could not be read.\n'
else
  printf 'board:\n%s\n' "$board"
fi
recovery="$(bash "$SCRIPTS/runtime.sh" recover 2>/dev/null || true)"
[ -z "$recovery" ] || printf '\nruntime recovery: %s\n' "$recovery"
exit 0
