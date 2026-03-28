#!/usr/bin/env bash
# Run the overview chat binary in foreground on the device with phosh Wayland env.
# Streams stderr/stdout back to this terminal for immediate crash diagnostics.
#
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-overview-chat-ui-remote-fg.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_SH=$(cat <<'REMOTE_SH'
set -eu
PID="$(pgrep phosh | head -n 1)"
if [ -z "$PID" ]; then
  echo "atomos: no process matched 'pgrep phosh'. Try: ps aux | grep phosh" >&2
  exit 1
fi
for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
  line="$(tr '\0' '\n' < "/proc/$PID/environ" | grep "^${v}=" || true)"
  [ -n "$line" ] || continue
  export "$line"
done
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
exec /usr/local/bin/atomos-overview-chat-ui
REMOTE_SH
)

exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
