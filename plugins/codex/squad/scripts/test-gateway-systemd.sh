#!/usr/bin/env bash
# Exercise the gateway template through the real user systemd manager. The
# fixture is runtime-only and never connects to, starts or rewrites a project.
set -euo pipefail
export SQUAD_CONTINUATION_MODE=legacy

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/systemd/squad-app-server-gateway@.service"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
FIXTURE="$RUNTIME_DIR/squad-gateway-systemd-test-$$"
UNIT_DIR="$RUNTIME_DIR/systemd/user"
UNIT="squad-gateway-systemd-test-$$.service"
UNIT_PATH="$UNIT_DIR/$UNIT"
RETRY_UNIT="squad-controller-retry-test-$$.service"
RETRY_UNIT_PATH="$UNIT_DIR/$RETRY_UNIT"
SOCKET="$FIXTURE/gateway.sock"

cleanup() {
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  systemctl --user stop "$RETRY_UNIT" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$RETRY_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_PATH" "$RETRY_UNIT_PATH"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  rm -rf -- "$FIXTURE"
}
trap cleanup EXIT INT TERM

command -v systemctl >/dev/null 2>&1 || { printf 'systemctl is required\n' >&2; exit 1; }
systemctl --user show-environment >/dev/null
mkdir -p "$FIXTURE/bin" "$FIXTURE/state" "$UNIT_DIR"

(
  cd "$ROOT/conductor-appserver"
  go build -o "$FIXTURE/bin/squad-conductor-appserver" .
)

cat >"$FIXTURE/gateway.env" <<EOF
SQUAD_CONDUCTOR_APP_SERVER_CLIENT=$FIXTURE/bin/squad-conductor-appserver
SQUAD_CONDUCTOR_APP_SERVER_URL=unix://$SOCKET
SQUAD_CONDUCTOR_APP_SERVER_UPSTREAM=unix://$FIXTURE/upstream.sock
SQUAD_CONDUCTOR_STATE=$FIXTURE/state
EOF

# Keep ExecStart byte-for-byte from the shipped template. The fixture removes
# only the production dependency chain and points EnvironmentFile at its own
# harmless runtime data.
sed \
  -e '/^Requires=/d' \
  -e '/^After=/d' \
  -e "s|^EnvironmentFile=.*|EnvironmentFile=$FIXTURE/gateway.env|" \
  "$TEMPLATE" >"$UNIT_PATH"

systemctl --user daemon-reload
systemctl --user start "$UNIT"

gateway_ready=0
for _ in $(seq 1 50); do
  if systemctl --user is-active --quiet "$UNIT" && [ -S "$SOCKET" ]; then
    printf 'pass  gateway template expands the environment-supplied client as an argument\n'
    printf 'pass  gateway fixture is active and exposes %s\n' "$SOCKET"
    gateway_ready=1
    break
  fi
  sleep 0.1
done

if [ "$gateway_ready" -ne 1 ]; then
  systemctl --user status "$UNIT" --no-pager >&2 || true
  exit 1
fi

# Exercise the same lifetime start limit used by transient controller units.
# Each failure is deliberately slower than RestartSec. With a rolling window
# those spaced failures can eventually regain their allowance; infinity makes
# three starts the total budget for this unique unit.
cat >"$FIXTURE/bin/slow-fail" <<EOF
#!/usr/bin/env bash
printf 'start\n' >>"$FIXTURE/retry-starts"
sleep 1
exit 1
EOF
chmod +x "$FIXTURE/bin/slow-fail"
retry_starts() {
  if [ -f "$FIXTURE/retry-starts" ]; then
    wc -l <"$FIXTURE/retry-starts"
  else
    printf '0\n'
  fi
}
cat >"$RETRY_UNIT_PATH" <<EOF
[Unit]
StartLimitIntervalSec=infinity
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$FIXTURE/bin/slow-fail
Restart=on-failure
RestartSec=0.2
EOF
systemctl --user daemon-reload
systemctl --user start "$RETRY_UNIT"
for _ in $(seq 1 80); do
  starts="$(retry_starts)"
  state="$(systemctl --user show "$RETRY_UNIT" --property=ActiveState --value)"
  [ "$starts" -lt 3 ] || [ "$state" != failed ] || break
  sleep 0.1
done

starts="$(retry_starts)"
state="$(systemctl --user show "$RETRY_UNIT" --property=ActiveState --value)"
# Wait beyond one complete slow failure and restart delay. A fourth start here
# would show that elapsed time had reset the budget.
sleep 1.5
stable_starts="$(retry_starts)"
if [ "$state" != failed ] || [ "$starts" -ne 3 ] || [ "$stable_starts" -ne 3 ]; then
  systemctl --user status "$RETRY_UNIT" --no-pager >&2 || true
  printf 'expected three total slow-failure starts and a stable failed unit; got starts=%s stable_starts=%s state=%s\n' "$starts" "$stable_starts" "$state" >&2
  exit 1
fi
printf 'pass  lifetime controller retry budget stops three slow failures\n'
