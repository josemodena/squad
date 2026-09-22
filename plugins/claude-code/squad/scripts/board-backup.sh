#!/usr/bin/env bash
set -euo pipefail
SQUAD_TOOL=board-backup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
. "$SCRIPT_DIR/lib/settings.sh"
squad_load_settings
set +a
exec python3 "$SCRIPT_DIR/board_backup.py" "$@"
