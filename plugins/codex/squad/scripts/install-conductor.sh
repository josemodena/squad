#!/usr/bin/env bash
# Install the conductor as a per-project systemd user timer.
#
# The unit templates are copied into the user's systemd directory. Each
# project gets a private environment file, while a shared launcher finds the
# newest installed Squad plugin every time the timer runs. Plugin upgrades do
# not therefore leave the service pointing at an old version.
set -euo pipefail

SQUAD_TOOL="install-conductor.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$SCRIPT_DIR/lib/settings.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  install-conductor.sh [--project <dir>] [--name <name>] [--no-enable]
  install-conductor.sh [--project <dir>] [--name <name>] --uninstall
USAGE
  exit 1
}

project=""
instance=""
uninstall=0
enable=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)   project="${2:-}"; [ -n "$project" ] || usage; shift 2 ;;
    --name)      instance="${2:-}"; [ -n "$instance" ] || usage; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --no-enable) enable=0; shift ;;
    -h|--help)   usage ;;
    *) squad_die "Unknown option '$1'." ;;
  esac
done

UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/squad"
SERVICE_TEMPLATE="squad-conductor@.service"
TIMER_TEMPLATE="squad-conductor@.timer"
APP_SERVER_TEMPLATE="squad-app-server@.service"
GATEWAY_TEMPLATE="squad-app-server-gateway@.service"
SOURCE_DIR="$SQUAD_ROOT_DIR/systemd"

command -v systemctl >/dev/null 2>&1 \
  || squad_die "systemctl is not available, so there is no user timer to install."
[ -f "$SOURCE_DIR/$SERVICE_TEMPLATE" ] && [ -f "$SOURCE_DIR/$TIMER_TEMPLATE" ] \
  && [ -f "$SOURCE_DIR/$APP_SERVER_TEMPLATE" ] && [ -f "$SOURCE_DIR/$GATEWAY_TEMPLATE" ] \
  || squad_die "The unit files are missing from $SOURCE_DIR."

if [ -n "$project" ]; then
  [ -d "$project" ] || squad_die "No directory at $project"
  project="$(cd "$project" && pwd)"
  SQUAD_PROJECT_DIR="$project"
fi
squad_load_settings
project="$(squad_project_dir)"
[ -r "$project/.codex/squad.local.md" ] \
  || squad_die "No Squad settings at $project/.codex/squad.local.md. Name the project with --project."

if [ -z "$instance" ]; then instance="$(squad_slug "$SQUAD_REPOSITORY")"; fi
case "$instance" in
  *[!a-zA-Z0-9_.-]*) squad_die "The instance name may contain letters, numbers, dot, underscore and hyphen only." ;;
esac
SERVICE="squad-conductor@${instance}.service"
TIMER="squad-conductor@${instance}.timer"
APP_SERVER_SERVICE="squad-app-server@${instance}.service"
GATEWAY_SERVICE="squad-app-server-gateway@${instance}.service"

if [ "$uninstall" -eq 1 ]; then
  systemctl --user disable --now "$TIMER" 2>/dev/null || true
  systemctl --user disable --now "$GATEWAY_SERVICE" "$APP_SERVER_SERVICE" 2>/dev/null || true
  rm -f "$CONF_DIR/$instance.env"
  systemctl --user daemon-reload
  printf 'The %s conductor is disabled. Shared unit templates and launcher remain installed.\n' "$instance"
  exit 0
fi

mkdir -p "$UNIT_DIR" "$CONF_DIR/bin" "$SQUAD_SCRATCH_ROOT"
runtime="$SQUAD_SCRATCH_ROOT/conductor-$instance"
mkdir -p "$runtime"

command -v go >/dev/null 2>&1 || squad_die "Go is required to build the App Server conductor adapter."
(cd "$SQUAD_ROOT_DIR/conductor-appserver" && go build -o "$CONF_DIR/bin/squad-conductor-appserver" .)

# Resolve the current installation at run time. SQUAD_PLUGIN_ROOT supports a
# development checkout; installed versions live in the Codex plugin cache.
LAUNCHER="$CONF_DIR/launcher-codex.sh"
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
# Written by Squad's install-conductor.sh. Rerun the installer to replace it.
set -euo pipefail

is_plugin() { [ -f "$1/.codex-plugin/plugin.json" ] && [ -d "$1/scripts" ]; }

root=""
if [ -n "${SQUAD_PLUGIN_ROOT:-}" ] && is_plugin "$SQUAD_PLUGIN_ROOT"; then
  root="$SQUAD_PLUGIN_ROOT"
fi

codex_home="${CODEX_HOME:-$HOME/.codex}"
if [ -z "$root" ]; then
  while IFS= read -r candidate; do
    is_plugin "$candidate" || continue
    root="$candidate"
  done < <(printf '%s\n' "$codex_home"/plugins/cache/*/squad/* | sort -V)
fi

if [ -z "$root" ]; then
  printf 'squad conductor: the Squad plugin is not installed, so there is nothing to run.\n' >&2
  exit 1
fi

exec bash "$root/scripts/conductor.sh" "$@"
LAUNCH
chmod 0755 "$LAUNCHER"

umask 077
cat > "$CONF_DIR/$instance.env" <<ENV
# Written by install-conductor.sh on $(date -u '+%Y-%m-%d %H:%M UTC').
# Rerun it after moving the project. Plugin updates need no rerun.
SQUAD_CONDUCTOR_SCRIPT=$LAUNCHER
SQUAD_PROJECT_DIR=$project
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
PATH=$PATH
SQUAD_CONDUCTOR_APP_SERVER_CLIENT=$CONF_DIR/bin/squad-conductor-appserver
SQUAD_CONDUCTOR_APP_SERVER_URL=unix://$runtime/gateway.sock
SQUAD_CONDUCTOR_APP_SERVER_UPSTREAM=unix://$runtime/app-server.sock
SQUAD_CONDUCTOR_STATE=$runtime/state
SQUAD_CONDUCTOR_LOG=$runtime/conductor.log
SQUAD_CONDUCTOR_LEDGER=$runtime/conductor-ledger.jsonl
SQUAD_CONDUCTOR_HOLD=$runtime/conductor.hold
ENV
umask 022

# Copy rather than link: the templates remain valid when the cache path of the
# plugin changes during an upgrade.
install -m 0644 "$SOURCE_DIR/$SERVICE_TEMPLATE" "$UNIT_DIR/$SERVICE_TEMPLATE"
install -m 0644 "$SOURCE_DIR/$TIMER_TEMPLATE" "$UNIT_DIR/$TIMER_TEMPLATE"
install -m 0644 "$SOURCE_DIR/$APP_SERVER_TEMPLATE" "$UNIT_DIR/$APP_SERVER_TEMPLATE"
install -m 0644 "$SOURCE_DIR/$GATEWAY_TEMPLATE" "$UNIT_DIR/$GATEWAY_TEMPLATE"
systemctl --user daemon-reload

# Releases before the per-project timer used one global instance. Disable it
# only when its generated environment names this exact project. A different or
# unreadable owner is left untouched and reported; the installer never guesses.
legacy_env="$CONF_DIR/conductor.env"
if [ -r "$legacy_env" ]; then
  legacy_project="$(sed -n 's/^SQUAD_PROJECT_DIR=//p' "$legacy_env" | head -1)"
  if [ "$legacy_project" = "$project" ]; then
    systemctl --user disable --now squad-conductor.timer 2>/dev/null || true
    printf '  migration  disabled legacy squad-conductor.timer owned by this project\n'
  elif [ -n "$legacy_project" ]; then
    printf 'warning: legacy squad-conductor.timer names %s; it was not changed\n' "$legacy_project" >&2
  else
    printf 'warning: %s has no readable project owner; legacy timer was not changed\n' "$legacy_env" >&2
  fi
fi

# Lingering keeps user services running after logout and across reboots.
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER" 2>/dev/null \
    || sudo -n loginctl enable-linger "$USER" 2>/dev/null \
    || printf 'Could not enable lingering. Run: sudo loginctl enable-linger %s\n' "$USER" >&2
fi

if [ "$enable" -eq 1 ]; then
  # The timer enables the conductor across boots. Its explicit Requires chain
  # starts the gateway and backend before every tick; start that chain now so
  # inspect/attach is also available between ticks. The two support templates
  # are intentionally static units and must not be passed to `enable`.
  systemctl --user start "$GATEWAY_SERVICE"
  systemctl --user enable --now "$TIMER"
fi

printf 'Conductor installed for %s\n' "$project"
printf '  instance   %s\n' "$instance"
printf '  units      %s, %s (copied from %s)\n' "$SERVICE" "$TIMER" "$SOURCE_DIR"
printf '  app server %s behind arbiter %s\n' "$APP_SERVER_SERVICE" "$GATEWAY_SERVICE"
printf '  attach     squad --harness codex session attach\n'
printf '  launcher   %s (finds the installed plugin at every run)\n' "$LAUNCHER"
printf '  settings   %s\n' "$CONF_DIR/$instance.env"
printf '  log        %s\n' "$runtime/conductor.log"
printf '  hold       touch %s to stop it starting sessions\n' "$runtime/conductor.hold"
if [ "$enable" -eq 1 ]; then
  systemctl --user list-timers "$TIMER" --no-pager || true
else
  printf '  the timer is installed but not enabled: systemctl --user enable --now %s\n' "$TIMER"
fi
