#!/usr/bin/env bash
# Runtime smoke test for Phosh stability during first pull-down interaction.
#
# Usage:
#   export ATOMOS_DEVICE_SSHPASS='...'
#   bash scripts/device/atomos-phosh-runtime-smoke.sh [watch-seconds]
#
# The script snapshots the current Phosh PID/start time, asks you to open the
# top pull-down once, then checks whether Phosh restarted/crashed in the window.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WATCH_SECONDS="${1:-20}"

if ! [[ "$WATCH_SECONDS" =~ ^[0-9]+$ ]] || [ "$WATCH_SECONDS" -lt 5 ]; then
    echo "Usage: $0 [watch-seconds>=5]" >&2
    exit 1
fi

REMOTE_SH="$(cat <<'REMOTE_SH'
set -eu
WATCH_SECONDS="__WATCH_SECONDS__"

get_phosh_pid() {
  pgrep phosh | head -n 1 || true
}

get_start_ticks() {
  pid="$1"
  # /proc/<pid>/stat field 22 = starttime (clock ticks since boot)
  awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true
}

TS_BEGIN="$(date -Iseconds)"
PID0="$(get_phosh_pid)"
if [ -z "$PID0" ]; then
  echo "ERROR: no running phosh process found." >&2
  exit 1
fi
START0="$(get_start_ticks "$PID0")"
if [ -z "$START0" ]; then
  echo "ERROR: unable to read /proc/$PID0/stat start ticks." >&2
  exit 1
fi

echo "=== phosh runtime smoke ==="
echo "baseline pid=$PID0 start_ticks=$START0"
echo "window=${WATCH_SECONDS}s"
echo ""
echo "Now open the top pull-down once on the device."
echo "Watching for phosh restart/crash..."

i=0
RESTARTED=0
while [ "$i" -lt "$WATCH_SECONDS" ]; do
  sleep 1
  PID_NOW="$(get_phosh_pid)"
  if [ -z "$PID_NOW" ]; then
    RESTARTED=1
    break
  fi
  START_NOW="$(get_start_ticks "$PID_NOW")"
  if [ -z "$START_NOW" ]; then
    RESTARTED=1
    break
  fi
  if [ "$PID_NOW" != "$PID0" ] || [ "$START_NOW" != "$START0" ]; then
    RESTARTED=1
    break
  fi
  i=$((i + 1))
done

echo ""
echo "=== process result ==="
PID1="$(get_phosh_pid)"
if [ -n "$PID1" ]; then
  START1="$(get_start_ticks "$PID1")"
  echo "current pid=$PID1 start_ticks=${START1:-<unknown>}"
else
  echo "current pid=<missing>"
fi

if [ "$RESTARTED" -eq 1 ]; then
  echo "RESULT: FAIL (phosh restarted/disappeared during watch window)"
else
  echo "RESULT: PASS (no phosh restart detected in watch window)"
fi

echo ""
echo "=== crash hints since baseline ==="
journalctl -b --since "$TS_BEGIN" --no-pager 2>/dev/null \
  | grep -Ei 'phosh|segfault|core dump|coredump|gjs|mutter|feedbackd|fatal|assert|trap' \
  || echo "(no matching crash hints in journal since baseline)"

echo ""
echo "=== coredumps (recent phosh-related) ==="
coredumpctl list --no-pager 2>/dev/null \
  | grep -Ei 'phosh|gjs|mutter|feedbackd' \
  || echo "(no matching coredumps)"

if [ "$RESTARTED" -eq 1 ]; then
  exit 2
fi
REMOTE_SH
)"

REMOTE_SH="${REMOTE_SH//__WATCH_SECONDS__/$WATCH_SECONDS}"
exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"

