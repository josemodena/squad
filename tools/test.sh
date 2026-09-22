#!/usr/bin/env bash
# Fixture validation; never invoke live model work or project services.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 tools/check-repo.py
python3 tools/sync-package.py --check
python3 -m unittest discover -s tests -v
for harness in codex claude-code; do
  plugin="plugins/$harness/squad"
  python3 "$plugin/scripts/test_runtime.py"
  bash "$plugin/scripts/selftest.sh"
  bash "$plugin/scripts/test-finish-guards.sh"
done
bash plugins/codex/squad/scripts/test-conductor-events.sh
(cd plugins/codex/squad/conductor-appserver && go test -race ./...)
git diff --check
