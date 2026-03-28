#!/usr/bin/env bash
# Print overview-chat-ui launcher log + recent journal lines on the device (for SSH debugging).
#
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-overview-chat-ui-remote-diag.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_SH=$(cat <<'REMOTE_SH'
set -eu
PID="$(pgrep phosh | head -n 1)"
if [ -z "$PID" ]; then
  echo "atomos: no process matched 'pgrep phosh'. Try: ps aux | grep phosh" >&2
  exit 1
fi
PHOSH_RUN="$(tr '\0' '\n' < "/proc/$PID/environ" | grep '^XDG_RUNTIME_DIR=' | sed 's/^XDG_RUNTIME_DIR=//' || true)"
[ -n "$PHOSH_RUN" ] || PHOSH_RUN="/tmp"
PHOSH_WL="$(tr '\0' '\n' < "/proc/$PID/environ" | grep '^WAYLAND_DISPLAY=' | sed 's/^WAYLAND_DISPLAY=//' || true)"

echo "=== phosh runtime env ==="
echo "PID=$PID"
echo "XDG_RUNTIME_DIR=$PHOSH_RUN"
echo "WAYLAND_DISPLAY=${PHOSH_WL:-<unset>}"
echo ""

echo "=== launcher/binary ==="
ls -l /usr/libexec/atomos-overview-chat-ui /usr/local/bin/atomos-overview-chat-ui 2>/dev/null || true
echo ""

echo "=== pidfile/process ==="
PIDFILE="$PHOSH_RUN/atomos-overview-chat-ui.pid"
if [ -f "$PIDFILE" ]; then
  echo "pidfile: $PIDFILE => $(cat "$PIDFILE" 2>/dev/null || true)"
else
  echo "pidfile missing: $PIDFILE"
fi
ps aux | grep '[a]tomos-overview-chat-ui' || true
echo ""

echo "=== $PHOSH_RUN/atomos-overview-chat-ui.log (tail) ==="
tail -n 60 "$PHOSH_RUN/atomos-overview-chat-ui.log" 2>/dev/null || echo "(no log at phosh runtime dir)"
echo ""
echo "=== /tmp/atomos-overview-chat-ui.log (tail) ==="
tail -n 60 /tmp/atomos-overview-chat-ui.log 2>/dev/null || echo "(no log in /tmp)"
echo ""
echo "=== journalctl -t atomos-overview-chat-ui (last 20) ==="
journalctl -t atomos-overview-chat-ui -n 20 --no-pager 2>/dev/null || true
REMOTE_SH
)

exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
