#!/usr/bin/env bash
# Run /usr/libexec/atomos-overview-chat-ui --show on the device with WAYLAND_DISPLAY
# (and friends) copied from the running phosh process. Use when testing over SSH.
#
# Requires: same user on device as graphical session (e.g. user), and phosh running.
# From iso-postmarketos/:
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-overview-chat-ui-remote-show.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_BODY=$(cat <<'REMOTE_SH'
set -eu
if ! pgrep -u "$(id -u)" phosh >/dev/null 2>&1; then
  echo "atomos: no phosh process for uid $(id -u). Try: ps aux | grep phosh" >&2
  exit 1
fi
bind_phosh_wayland_env
LOG="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.log"
{
  echo "---- remote-show $(date) ----"
  echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
  echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
} >>"$LOG" 2>/dev/null || true
exec /usr/libexec/atomos-overview-chat-ui --show
REMOTE_SH
)

REMOTE_SH="$(cat "$ROOT_DIR/scripts/device/_lib-bind-phosh-wayland-env.sh")
${REMOTE_BODY}"
exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
