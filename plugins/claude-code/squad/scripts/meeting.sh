#!/usr/bin/env bash
set -euo pipefail
# Old meeting launch commands now enter the single main PM session.
if [ "${1:-}" = start ] && { [ "${2:-}" = planning ] || [ "${2:-}" = retro ]; }; then
  shift
  exec bash "$(dirname "${BASH_SOURCE[0]}")/start.sh" "$@"
fi
SQUAD_TOOL=meeting.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings
SQUAD_PROJECT_DIR="$(squad_project_dir)"
set +a
exec python3 "$SCRIPT_DIR/meeting.py" --harness claude-code "$@"
