#!/usr/bin/env bash
# Run the overview chat binary in foreground on the device with phosh Wayland env.
# Streams stderr/stdout back to this terminal for immediate crash diagnostics.
#
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-overview-chat-ui-remote-fg.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_BODY=$(cat <<'REMOTE_SH'
set -eu
if ! pgrep -u "$(id -u)" phosh >/dev/null 2>&1; then
  echo "atomos: no phosh process for uid $(id -u). Try: ps aux | grep phosh" >&2
  exit 1
fi
bind_phosh_wayland_env
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
exec /usr/local/bin/atomos-overview-chat-ui
REMOTE_SH
)

REMOTE_SH="$(cat "$ROOT_DIR/scripts/device/_lib-bind-phosh-wayland-env.sh")
${REMOTE_BODY}"
exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
