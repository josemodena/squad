#!/usr/bin/env bash
set -euo pipefail
SQUAD_TOOL=meeting.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings
SQUAD_PROJECT_DIR="$(squad_project_dir)"
set +a
exec python3 "$SCRIPT_DIR/meeting.py" --harness claude-code "$@"
