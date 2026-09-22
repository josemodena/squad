#!/usr/bin/env bash
# Stop: warn when the session is ending with unsaved work. It warns; it never
# blocks. A session that cannot stop is worse than a session that leaves a
# dirty tree, and the person is the one who decides which it is.
set -uo pipefail

cat >/dev/null 2>&1 || true   # drain the hook's JSON input

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || exit 0

settings=""
for candidate in "${SQUAD_SETTINGS:-}" "${CLAUDE_PROJECT_DIR:-}/.claude/squad.local.md" "$root/.claude/squad.local.md"; do
  [ -n "$candidate" ] || continue
  [ -r "$candidate" ] || continue
  settings="$candidate"
  break
done
if [ -z "$settings" ]; then
  printf '{"continue": true}\n'
  exit 0
fi

dirty="$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "${dirty:-0}" -gt 0 ] || exit 0

branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || echo 'a detached HEAD')"
message="Squad: $dirty path(s) are unsaved on $branch. Every session ends with the tree committed and pushed. Save with gitw.sh save \"<message>\" -- <paths>, or say why the work is being left."

printf '{"continue": true, "suppressOutput": false, "systemMessage": %s}\n' "$(printf '%s' "$message" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
exit 0
