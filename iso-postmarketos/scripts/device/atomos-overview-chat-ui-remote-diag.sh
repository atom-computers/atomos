#!/usr/bin/env bash
# Print overview-chat-ui launcher log + recent journal lines on the device (for SSH debugging).
#
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-overview-chat-ui-remote-diag.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_BODY=$(cat <<'REMOTE_SH'
set -eu
bind_phosh_wayland_env
PHOSH_PID="$(pgrep -u "$(id -u)" -x phosh 2>/dev/null | head -n 1 || true)"
[ -n "$PHOSH_PID" ] || PHOSH_PID="$(pgrep -u "$(id -u)" phosh 2>/dev/null | head -n 1 || true)"
PHOSH_RUN="${XDG_RUNTIME_DIR:-/tmp}"

echo "=== phosh runtime env ==="
echo "PID=${PHOSH_PID:-<none>}"
echo "XDG_RUNTIME_DIR=$PHOSH_RUN"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo ""

echo "=== launcher/binary ==="
ls -l /usr/libexec/atomos-overview-chat-ui /usr/local/bin/atomos-overview-chat-ui 2>/dev/null || true
if command -v readelf >/dev/null 2>&1 && [ -x /usr/local/bin/atomos-overview-chat-ui ]; then
  echo "--- ELF interpreter ---"
  readelf -l /usr/local/bin/atomos-overview-chat-ui 2>/dev/null | sed -n "s/.*Requesting program interpreter: \(.*\)]/\1/p"
fi
echo ""

echo "=== pidfile/process ==="
PIDFILE="$PHOSH_RUN/atomos-overview-chat-ui.pid"
if [ -f "$PIDFILE" ]; then
  echo "pidfile: $PIDFILE => $(cat "$PIDFILE" 2>/dev/null || true)"
else
  echo "pidfile missing: $PIDFILE"
fi
ps aux | grep "[a]tomos-overview-chat-ui" || true
echo ""

echo "=== $PHOSH_RUN/atomos-overview-chat-ui.log (tail) ==="
tail -n 80 "$PHOSH_RUN/atomos-overview-chat-ui.log" 2>/dev/null || echo "(no log at phosh runtime dir)"
echo ""
echo "=== /tmp/atomos-overview-chat-ui.log (tail) ==="
tail -n 80 /tmp/atomos-overview-chat-ui.log 2>/dev/null || echo "(no log in /tmp)"
echo ""
echo "=== journalctl -t atomos-overview-chat-ui (last 40) ==="
journalctl -t atomos-overview-chat-ui -n 40 --no-pager 2>/dev/null || true
echo ""
echo "=== coredumpctl (overview chat ui) ==="
if command -v coredumpctl >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    CDBASE="sudo coredumpctl"
  else
    CDBASE="coredumpctl"
  fi
  sh -c "$CDBASE list /usr/local/bin/atomos-overview-chat-ui --no-pager" 2>/dev/null || true
  latest="$(sh -c "$CDBASE list /usr/local/bin/atomos-overview-chat-ui --no-pager" 2>/dev/null | awk 'NF {id=$1} END {print id}')"
  if [ -z "$latest" ]; then
    latest="$(sh -c "$CDBASE list --no-pager" 2>/dev/null | grep 'atomos-overview-chat-ui' | awk 'NF {id=$1} END {print id}')"
  fi
  if [ -n "$latest" ]; then
    echo "--- coredumpctl info $latest ---"
    sh -c "$CDBASE info $latest --no-pager" 2>/dev/null || true
  else
    echo "(no matching coredump entries visible)"
  fi
else
  echo "(coredumpctl not available)"
fi
REMOTE_SH
)

REMOTE_SH="$(cat "$ROOT_DIR/scripts/device/_lib-bind-phosh-wayland-env.sh")
${REMOTE_BODY}"
exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
