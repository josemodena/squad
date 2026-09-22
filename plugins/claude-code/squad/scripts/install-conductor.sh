#!/usr/bin/env bash
# Install the conductor timer as a user service.
#
# It copies the two units into the user's systemd directory, writes the two
# generated files that tell them what to run and where the project is, enables
# the timer and keeps user services running after logout and across reboots.
#
# Nothing it installs names a plugin version. The units are copied rather than
# linked, and what they run is a launcher that finds the installed plugin at
# each run, so a plugin update needs no reinstall. Rerun this only when the
# project moves or the unit files themselves change.
#
# Everything that varies by machine lives in ~/.config/squad: launcher.sh, and
# conductor.env naming the launcher, the project directory whose settings it
# reads, and the PATH the tools were found on, because a systemd user service
# starts with a minimal one.
#
# Options:
#   --project <dir>   the project to run the conductor for (default: this one)
#   --uninstall       disable the timer and remove the links
#   --no-enable       install the files, but do not enable or start the timer
set -euo pipefail

SQUAD_TOOL="install-conductor.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  install-conductor.sh [--project <dir>] [--no-enable]
  install-conductor.sh --uninstall
USAGE
  exit 1
}

project=""
uninstall=0
enable=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)   project="${2:-}"; [ -n "$project" ] || usage; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --no-enable) enable=0; shift ;;
    -h|--help)   usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/squad"
SERVICE="squad-conductor.service"
TIMER="squad-conductor.timer"
SOURCE_DIR="$SQUAD_ROOT_DIR/systemd"

command -v systemctl >/dev/null 2>&1 || squad_die "systemctl is not available, so there is no user timer to install."

if [ "$uninstall" -eq 1 ]; then
  systemctl --user disable --now "$TIMER" 2>/dev/null || true
  rm -f "$UNIT_DIR/$TIMER" "$UNIT_DIR/$SERVICE"
  systemctl --user daemon-reload
  printf 'The conductor timer is removed. %s is left in place.\n' "$CONF_DIR"
  exit 0
fi

[ -f "$SOURCE_DIR/$SERVICE" ] && [ -f "$SOURCE_DIR/$TIMER" ] \
  || squad_die "The unit files are missing from $SOURCE_DIR."

if [ -n "$project" ]; then
  [ -d "$project" ] || squad_die "No directory at $project"
  project="$(cd "$project" && pwd)"
  SQUAD_PROJECT_DIR="$project"
fi
squad_load_settings
project="$(squad_project_dir)"
[ -r "$project/.claude/squad.local.md" ] \
  || squad_die "No Squad settings at $project/.claude/squad.local.md. Name the project with --project."

mkdir -p "$UNIT_DIR" "$CONF_DIR" "$SQUAD_SCRATCH_ROOT"

# The launcher, not the conductor itself, is what the service runs. It resolves
# the installed plugin at every run, newest version wins, so no path installed
# here carries a version number and an update needs no reinstall.
LAUNCHER="$CONF_DIR/launcher-claude-code.sh"
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
# Written by install-conductor.sh. Rerun it rather than editing this.
#
# Find the installed Squad plugin, then run its conductor. The order is the
# install record the harness keeps, then the newest version in the plugin
# cache. Resolving it here, at every run, is what keeps the systemd unit free
# of a version number.
set -euo pipefail

is_plugin() { [ -f "$1/.claude-plugin/plugin.json" ] && [ -d "$1/scripts" ]; }

root=""
if [ -n "${SQUAD_PLUGIN_ROOT:-}" ] && is_plugin "$SQUAD_PLUGIN_ROOT"; then
  root="$SQUAD_PLUGIN_ROOT"
fi

# Newest wins, at both steps. The record can hold more than one entry, one per
# scope, and an update touches only one of them; the cache keeps every version
# it has ever held. Versions sort by version, not by string, so that 0.1.10
# comes after 0.1.9 rather than before it.
record="$HOME/.claude/plugins/installed_plugins.json"
if [ -z "$root" ] && [ -r "$record" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_plugin "$candidate" || continue
    root="$candidate"
  done < <(jq -r '.plugins | to_entries[]
                  | select(.key | startswith("squad@"))
                  | .value[]
                  | [(.version // ""), (.installPath // "")] | @tsv' "$record" 2>/dev/null \
           | sort -V | cut -f2)
fi

if [ -z "$root" ]; then
  while IFS= read -r candidate; do
    is_plugin "$candidate" || continue
    root="$candidate"
  done < <(printf '%s\n' "$HOME"/.claude/plugins/cache/*/squad/* | sort -V)
fi

if [ -z "$root" ]; then
  printf 'squad conductor: the Squad plugin is not installed, so there is nothing to run.\n' >&2
  exit 1
fi

exec bash "$root/scripts/conductor.sh" "$@"
LAUNCH
chmod 0755 "$LAUNCHER"

umask 077
cat > "$CONF_DIR/conductor.env" <<ENV
# Written by install-conductor.sh on $(date -u '+%Y-%m-%d %H:%M UTC'). Rerun it
# after moving the project. A plugin update needs no rerun.
SQUAD_CONDUCTOR_SCRIPT=$LAUNCHER
SQUAD_PROJECT_DIR=$project
PATH=$PATH
ENV
umask 022

# Copied, not linked: a link would name the installed version, and the version
# changes under it at every update.
install -m 0644 "$SOURCE_DIR/$SERVICE" "$UNIT_DIR/$SERVICE"
install -m 0644 "$SOURCE_DIR/$TIMER" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload

# Without lingering, user services stop at logout and never come back after a
# reboot, which is the whole point of the timer.
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER" 2>/dev/null \
    || sudo -n loginctl enable-linger "$USER" 2>/dev/null \
    || printf 'Could not enable lingering. Run: sudo loginctl enable-linger %s\n' "$USER" >&2
fi

if [ "$enable" -eq 1 ]; then
  systemctl --user enable --now "$TIMER"
fi

printf 'Conductor installed for %s\n' "$project"
printf '  units      %s, %s (copied from %s)\n' "$SERVICE" "$TIMER" "$SOURCE_DIR"
printf '  launcher   %s (finds the installed plugin at every run)\n' "$LAUNCHER"
printf '  settings   %s\n' "$CONF_DIR/conductor.env"
printf '  log        %s\n' "$SQUAD_SCRATCH_ROOT/conductor.log"
printf '  hold       touch %s to stop it starting sessions\n' "$SQUAD_SCRATCH_ROOT/conductor.hold"
if [ "$enable" -eq 1 ]; then
  systemctl --user list-timers "$TIMER" --no-pager || true
else
  printf '  the timer is installed but not enabled: systemctl --user enable --now %s\n' "$TIMER"
fi
