#!/usr/bin/env bash
# Reproduce overview-chat-ui crashes by repeatedly toggling show/hide on device.
#
# Usage:
#   export ATOMOS_DEVICE_SSHPASS='...'
#   bash scripts/device/atomos-overview-chat-ui-segfault-repro.sh [iterations] [sleep-ms]
#
# Example:
#   bash scripts/device/atomos-overview-chat-ui-segfault-repro.sh 20 300
#
# Exit codes:
#   0 = no new coredump detected during this run
#   2 = new coredump(s) detected for atomos-overview-chat-ui
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ITERATIONS="${1:-12}"
SLEEP_MS="${2:-250}"

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
    echo "Usage: $0 [iterations>=1] [sleep-ms>=50]" >&2
    exit 1
fi
if ! [[ "$SLEEP_MS" =~ ^[0-9]+$ ]] || [ "$SLEEP_MS" -lt 50 ]; then
    echo "Usage: $0 [iterations>=1] [sleep-ms>=50]" >&2
    exit 1
fi

REMOTE_SH="$(cat <<'REMOTE_SH'
set -eu
ITERATIONS="__ITERATIONS__"
SLEEP_MS="__SLEEP_MS__"
SLEEP_SEC="$(awk "BEGIN { printf \"%.3f\", ${SLEEP_MS}/1000 }")"
TS_BEGIN="$(date -Iseconds)"

count_overview_coredumps() {
  if ! command -v coredumpctl >/dev/null 2>&1; then
    echo "0"
    return 0
  fi
  coredumpctl list /usr/local/bin/atomos-overview-chat-ui --no-pager 2>/dev/null \
    | awk 'NF {c++} END {print c+0}'
}

get_last_overview_coredump_id() {
  if ! command -v coredumpctl >/dev/null 2>&1; then
    return 0
  fi
  coredumpctl list /usr/local/bin/atomos-overview-chat-ui --no-pager 2>/dev/null \
    | awk 'NF {id=$1} END {print id}'
}

PID="$(pgrep phosh | head -n 1 || true)"
if [ -z "$PID" ]; then
  echo "ERROR: no running phosh process found." >&2
  exit 1
fi

for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
  line="$(tr '\0' '\n' < "/proc/$PID/environ" | grep "^${v}=" || true)"
  [ -n "$line" ] || continue
  export "$line"
done

echo "=== overview chat ui segfault repro ==="
echo "iterations=$ITERATIONS sleep_ms=$SLEEP_MS"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
echo "timestamp_begin=$TS_BEGIN"
echo ""

BASE_CORES="$(count_overview_coredumps)"
echo "baseline_coredumps=$BASE_CORES"

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  /usr/libexec/atomos-overview-chat-ui --show >/dev/null 2>&1 || true
  sleep "$SLEEP_SEC"
  /usr/libexec/atomos-overview-chat-ui --hide >/dev/null 2>&1 || true
  sleep "$SLEEP_SEC"
  i=$((i + 1))
done

echo ""
echo "=== process and logs ==="
ps aux | grep "[a]tomos-overview-chat-ui" || true
echo ""
journalctl -t atomos-overview-chat-ui --since "$TS_BEGIN" --no-pager 2>/dev/null || true
echo ""
journalctl -b --since "$TS_BEGIN" --no-pager 2>/dev/null \
  | grep -Ei 'atomos-overview-chat-ui|segfault|core dump|coredump|fatal|assert|trap' \
  || true

END_CORES="$(count_overview_coredumps)"
DELTA=$((END_CORES - BASE_CORES))
echo ""
echo "coredumps_after=$END_CORES delta=$DELTA"

if [ "$DELTA" -gt 0 ]; then
  echo "RESULT: FAIL (new overview-chat-ui coredump detected)"
  LAST_ID="$(get_last_overview_coredump_id)"
  if [ -n "$LAST_ID" ]; then
    echo "--- latest coredumpctl info $LAST_ID ---"
    coredumpctl info "$LAST_ID" --no-pager 2>/dev/null || true
  fi
  exit 2
fi

echo "RESULT: PASS (no new overview-chat-ui coredump detected)"
REMOTE_SH
)"

REMOTE_SH="${REMOTE_SH//__ITERATIONS__/$ITERATIONS}"
REMOTE_SH="${REMOTE_SH//__SLEEP_MS__/$SLEEP_MS}"
exec bash "$ROOT_DIR/scripts/device/atomos-device-ssh.sh" /bin/sh -lc "$REMOTE_SH"
