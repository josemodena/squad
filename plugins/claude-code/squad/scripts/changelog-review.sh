#!/usr/bin/env bash
# Review the releases of the tools the squad runs on since the version last
# reviewed. The retrospective runs it, a cheap agent classifies each entry
# adopt or ignore in one line, and the version file is then moved forward.
#
#   bash scripts/changelog-review.sh
#   bash scripts/changelog-review.sh --version-file <path> --watchlist <path>
#   bash scripts/changelog-review.sh --version 2.1.270       one-off, no file
#   bash scripts/changelog-review.sh --all                   no watch list
#
# The reading is the cost, so the script does it and the agent judges what is
# left. Only the entries newer than the recorded version are printed, and only
# those whose text matches a term in the watch list.
#
# Nothing newer than the recorded version prints nothing at all on standard
# output, which is what makes it safe to run every sprint.
#
# The changelog, the version file and the watch list all come from
# .claude/squad.local.md, and each can be overridden on the command line. The
# default source is the Claude Code changelog for this integration; a project
# using another release source sets harness_changelog_url.
set -euo pipefail

SQUAD_TOOL="changelog-review.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

squad_load_settings

PROJECT_DIR="$(squad_project_dir)"
URL="$SQUAD_HARNESS_CHANGELOG_URL"
VERSION_FILE="$SQUAD_HARNESS_VERSION_FILE"
WATCHLIST="$SQUAD_HARNESS_WATCHLIST"
VERSION=""
FILTER=1

usage() {
  cat >&2 <<'USAGE'
Usage:
  changelog-review.sh [--version-file <path>]
                      [--watchlist <path>]
                      [--version <x.y.z>]
                      [--url <url>]
                      [--all]

The paths default to this project's settings in .claude/squad.local.md.
A relative path is read from the project directory.
USAGE
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version-file) VERSION_FILE="${2:-}"; [ -n "$VERSION_FILE" ] || usage; shift 2 ;;
    --watchlist)    WATCHLIST="${2:-}"; [ -n "$WATCHLIST" ] || usage; shift 2 ;;
    --version)      VERSION="${2:-}"; [ -n "$VERSION" ] || usage; shift 2 ;;
    --url)          URL="${2:-}"; [ -n "$URL" ] || usage; shift 2 ;;
    --all)          FILTER=0; shift ;;
    -h|--help)      usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$PROJECT_DIR" "$1" ;;
  esac
}

# --- the version last reviewed ----------------------------------------------

if [ -z "$VERSION" ]; then
  [ -n "$VERSION_FILE" ] || squad_die \
    "No version file is set. Put harness_version_file in $SQUAD_SETTINGS_FILE, or pass --version-file or --version."
  VERSION_FILE="$(absolute "$VERSION_FILE")"
  [ -r "$VERSION_FILE" ] || squad_die "Cannot read the version file: $VERSION_FILE"
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ -n "$VERSION" ] || squad_die "The version file is empty: $VERSION_FILE"
else
  VERSION_FILE="$([ -n "$VERSION_FILE" ] && absolute "$VERSION_FILE" || printf '')"
fi

case "$VERSION" in
  *[!0-9.]*) squad_die "The recorded version must read as digits and dots; it reads '$VERSION'." ;;
esac

# --- the watch list ---------------------------------------------------------

TERMS=""
PATTERN=""
if [ "$FILTER" -eq 1 ] && [ -n "$WATCHLIST" ]; then
  WATCHLIST="$(absolute "$WATCHLIST")"
  [ -r "$WATCHLIST" ] || squad_die "Cannot read the watch list: $WATCHLIST"
  TERMS="$(sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WATCHLIST" | grep -v '^$' || true)"
  [ -n "$TERMS" ] || squad_die "The watch list has no terms in it: $WATCHLIST"
  PATTERN="$(printf '%s\n' "$TERMS" | paste -sd'|' -)"
elif [ "$FILTER" -eq 1 ]; then
  FILTER=0
fi

# --- the changelog ----------------------------------------------------------

command -v curl >/dev/null 2>&1 || squad_die "curl is not installed."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-changelog-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --max-time 60 "$URL" -o "$WORK/CHANGELOG.md" \
  || squad_die "Could not fetch the changelog from $URL"

# Every "## <version>" heading newer than the recorded one, newest first.
# The recorded version is sorted into the list, and what lands after it is
# what is newer. That holds whether or not the changelog still carries it.
NEWER="$( { printf '%s\n' "$VERSION"
            awk '/^##[ \t]+[0-9]/ { v = $2; sub(/\r$/, "", v); print v }' "$WORK/CHANGELOG.md"
          } | sort -V -u \
            | awk -v cur="$VERSION" 'seen { print } $0 == cur { seen = 1 }' \
            | sort -Vr)"

if [ -z "$NEWER" ]; then
  printf '%s: nothing newer than %s at %s\n' "$SQUAD_TOOL" "$VERSION" "$URL" >&2
  exit 0
fi

LATEST="$(printf '%s\n' "$NEWER" | head -1)"
VERSION_COUNT="$(printf '%s\n' "$NEWER" | wc -l | tr -d ' ')"

# --- the report -------------------------------------------------------------

report="$WORK/report"
: > "$report"
shown=0
entries=0

while IFS= read -r v; do
  [ -n "$v" ] || continue
  body="$(awk -v want="$v" '
    { sub(/\r$/, "") }
    /^##[ \t]+[0-9]/ { inside = ($2 == want); next }
    inside && /^[-*][ \t]/ { print }
  ' "$WORK/CHANGELOG.md")"
  if [ "$FILTER" -eq 1 ]; then
    body="$(printf '%s\n' "$body" | { grep -iE "$PATTERN" || true; })"
  fi
  [ -n "$body" ] || continue
  shown=$((shown + 1))
  entries=$((entries + $(printf '%s\n' "$body" | grep -c . || true)))
  {
    printf '\n## %s\n\n' "$v"
    printf '%s\n' "$body"
  } >> "$report"
done <<EOL
$NEWER
EOL

printf '\n=== Releases since %s ===\n' "$VERSION"
printf 'source:     %s\n' "$URL"
if [ "$FILTER" -eq 1 ]; then
  printf 'watch list: %s\n' "$(printf '%s\n' "$TERMS" | paste -sd, - | sed 's/,/, /g')"
else
  printf 'watch list: none, every entry is shown\n'
fi
printf 'versions:   %s newer, up to %s\n' "$VERSION_COUNT" "$LATEST"

if [ "$shown" -eq 0 ]; then
  printf '\nNo entry in those %s version(s) matches the watch list.\n' "$VERSION_COUNT"
else
  cat "$report"
  printf '\n%s entries on the watch list, in %s of the %s newer version(s).\n' \
    "$entries" "$shown" "$VERSION_COUNT"
fi

printf '\nClassify each entry adopt or ignore with one line of reason, put the result\n'
printf 'on the retrospective issue, then record the version reviewed:\n'
if [ -n "$VERSION_FILE" ]; then
  printf "  printf '%s\\\\n' > %s\n" "$LATEST" "$VERSION_FILE"
else
  printf '  %s\n' "$LATEST"
fi
