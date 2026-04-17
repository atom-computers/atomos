#!/usr/bin/env bash
set -euo pipefail
# Avoid background job termination notifications while we intentionally stop
# live log follower processes.
set +m

usage() {
    cat <<'EOF'
Usage: diagnose-phosh-home-chat-ui-crash.sh <profile-env> <ssh-target> [--seconds N] [--out-dir PATH]

Collects phosh crash/disappear diagnostics from a target device.

Modes:
  interactive (default)  waits for you to reproduce, press Enter to collect
  --seconds N            records for N seconds, then collects automatically

Examples:
  bash scripts/phosh/diagnose-phosh-home-chat-ui-crash.sh config/arm64-virt.env user@127.0.0.1
  bash scripts/phosh/diagnose-phosh-home-chat-ui-crash.sh config/fairphone-fp4.env user@172.16.42.1 --seconds 25
EOF
}

if [ "$#" -lt 2 ]; then
    usage >&2
    exit 2
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
shift 2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: $1 is required." >&2
        exit 1
    }
}

need_cmd ssh
need_cmd rg

COLLECT_SECONDS=""
OUT_BASE="${ATOMOS_PHOSH_DIAG_OUT_DIR:-$ROOT_DIR/build/phosh-diag}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --seconds)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --seconds requires value" >&2; exit 2; }
            COLLECT_SECONDS="$1"
            ;;
        --out-dir)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --out-dir requires value" >&2; exit 2; }
            OUT_BASE="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_COMMON_OPTS=(
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
CONTROL_PATH="/tmp/atomos-phosh-diag-%C.sock"
cleanup_control() {
    ssh "${SSH_COMMON_OPTS[@]}" -o ControlPath="$CONTROL_PATH" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
    rm -f "$CONTROL_PATH" >/dev/null 2>&1 || true
}
trap cleanup_control EXIT

if [ -n "${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}" ]; then
    need_cmd sshpass
    SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}"
    SSH_CMD=(
        sshpass -p "$SSH_PASSWORD"
        ssh
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        -o KbdInteractiveAuthentication=no
        -o NumberOfPasswordPrompts=1
        -o ControlMaster=auto
        -o ControlPersist=120
        -o ControlPath="$CONTROL_PATH"
        "${SSH_COMMON_OPTS[@]}"
    )
else
    # Ask once up front for password auth so repeated collections don't prompt each command.
    if [ -z "${SSH_ASKPASS_REQUIRE:-}" ]; then
        echo "SSH password auth is expected. Set ATOMOS_DEVICE_SSHPASS/SSHPASS to avoid prompts." >&2
    fi
    SSH_CMD=(
        ssh
        -o ControlMaster=auto
        -o ControlPersist=120
        -o ControlPath="$CONTROL_PATH"
        "${SSH_COMMON_OPTS[@]}"
    )
fi

ssh_run() {
    "${SSH_CMD[@]}" "$SSH_TARGET" "$1"
}

ssh_wait_until_reachable() {
    local attempts="${1:-15}"
    local delay_s="${2:-2}"
    local i
    for i in $(seq 1 "$attempts"); do
        if ssh_run "true" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay_s"
    done
    return 1
}

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_BASE/$TS"
mkdir -p "$OUT_DIR"

REMOTE_TMP="/tmp/atomos-phosh-diag-$TS"
MARKER="ATOMOS_PHOSH_DIAG_BEGIN_$TS"

echo "Checking connectivity to $SSH_TARGET ..."
ssh_run "printf 'connected user=%s host=%s\n' \"\$(id -un)\" \"\$(hostname)\""

echo "Creating remote diagnostic marker..."
ssh_run "/bin/sh -eu -c 'mkdir -p \"$REMOTE_TMP\"; printf \"%s\n\" \"$MARKER\" > \"$REMOTE_TMP/marker\"; logger -t atomos-phosh-diag \"$MARKER\"'"

# Capture logs live during reproduction so we keep evidence even if SSH drops later.
echo "Starting live log capture during repro window..."
(
    ssh_run "journalctl --user -b _COMM=phosh -f -n 0 --no-pager" \
        > "$OUT_DIR/live-phosh-follow.log" 2>&1
) &
FOLLOW_PHOSH_PID=$!
(
    ssh_run "journalctl -b -f -n 0 --no-pager | rg -i 'phosh|segfault|core dumped|assert|fatal|dragsurface|home\\.c'" \
        > "$OUT_DIR/live-boot-filter-follow.log" 2>&1
) &
FOLLOW_BOOT_PID=$!

if [ -n "$COLLECT_SECONDS" ]; then
    echo "Reproduce now: opening/closing for $COLLECT_SECONDS seconds..."
    sleep "$COLLECT_SECONDS"
else
    echo "Reproduce now: rapidly open/close until failure, then press Enter."
    read -r -p "> Press Enter to collect diagnostics... " _
fi

kill "$FOLLOW_PHOSH_PID" "$FOLLOW_BOOT_PID" >/dev/null 2>&1 || true
wait "$FOLLOW_PHOSH_PID" "$FOLLOW_BOOT_PID" >/dev/null 2>&1 || true

echo "Collecting logs and status..."
if ! ssh_wait_until_reachable 20 2; then
    echo "WARN: target unreachable after repro window; saving partial diagnostics." >&2
    {
        echo "target unreachable after repro"
        echo "ssh_target=$SSH_TARGET"
        echo "timestamp=$TS"
    } > "$OUT_DIR/target-unreachable.txt"
else
    ssh_run "journalctl --user -u phosh -b --no-pager -n 500" > "$OUT_DIR/phosh-user-unit.log" || true
    ssh_run "journalctl --user -b _COMM=phosh --no-pager -n 800" > "$OUT_DIR/phosh-comm.log" || true
    ssh_run "journalctl -b --no-pager -n 1200 | rg -i 'phosh|segfault|core dumped|assert|fatal|dragsurface|home\\.c'" > "$OUT_DIR/boot-phosh-filtered.log" || true
    ssh_run "journalctl --user -b --no-pager | sed -n '/$MARKER/,\$p'" > "$OUT_DIR/since-marker-user.log" || true
    ssh_run "journalctl -b --no-pager | sed -n '/$MARKER/,\$p'" > "$OUT_DIR/since-marker-boot.log" || true
    ssh_run "coredumpctl --no-pager --no-legend | tail -n 60" > "$OUT_DIR/coredumps-tail.log" || true
    ssh_run "coredumpctl --no-pager --no-legend | rg -i 'phosh|gnome-shell|gtk|segv|abort' || true" > "$OUT_DIR/coredumps-filtered.log" || true
    ssh_run "pidof phosh || true" > "$OUT_DIR/phosh-pid.txt" || true
    ssh_run "systemctl --user --no-pager list-units --all | rg -i 'phosh|mobi\\.phosh' || true" > "$OUT_DIR/phosh-user-units.log" || true
    ssh_run "if systemctl --user list-units --all --plain --no-legend | rg -q '^phosh\\.service\\b'; then systemctl --user --no-pager status phosh.service; else echo 'phosh.service not present in user manager'; fi" > "$OUT_DIR/phosh-systemctl-status.log" || true
    ssh_run "loginctl session-status \"\${XDG_SESSION_ID:-}\" 2>/dev/null || true" > "$OUT_DIR/session-status.log" || true

    ssh_run "/bin/sh -eu -c 'logger -t atomos-phosh-diag \"ATOMOS_PHOSH_DIAG_END_$TS\"; rm -rf \"$REMOTE_TMP\"'" || true
fi

HANDLE_FAIL_COUNT="$(
    (
        rg -c 'Failed to get handle position' "$OUT_DIR"/*.log 2>/dev/null || true
    ) | awk -F: '{sum += $2} END {print sum + 0}'
)"
SEGV_COUNT="$(
    (
        rg -c -i 'segfault|sigsegv|core dumped|trace/breakpoint trap|assertion.*failed' "$OUT_DIR"/*.log 2>/dev/null || true
    ) | awk -F: '{sum += $2} END {print sum + 0}'
)"

cat > "$OUT_DIR/summary.txt" <<EOF
phosh diagnostics summary
timestamp=$TS
ssh_target=$SSH_TARGET
profile_env=$PROFILE_ENV_SOURCE
phosh_pid=$(tr -d '\n' < "$OUT_DIR/phosh-pid.txt" 2>/dev/null || true)
failed_handle_position_count=$HANDLE_FAIL_COUNT
segv_or_fatal_marker_count=$SEGV_COUNT
EOF

echo
echo "Diagnostics saved: $OUT_DIR"
echo "Summary:"
cat "$OUT_DIR/summary.txt"
