#!/usr/bin/env bash
# Integration test wrapper for Phosh home chat UI lifecycle regressions.
#
# Runs timed diagnostics collection on a target and fails on known bad signals:
# - popup/subsurface mapped with unmapped parent
# - user manager/session teardown during repro window
# - missing phosh pid after repro
# - phosh coredumps
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: test-phosh-home-chat-ui-integration.sh <profile-env> <ssh-target> [--seconds N] [--diag-out PATH]

Examples:
  bash scripts/phosh/test-phosh-home-chat-ui-integration.sh config/arm64-virt.env user@127.0.0.1 --seconds 25
  bash scripts/phosh/test-phosh-home-chat-ui-integration.sh config/fairphone-fp4.env user@172.16.42.1

Environment overrides:
  ATOMOS_PHOSH_INTEGRATION_SECONDS=25
  ATOMOS_PHOSH_INTEGRATION_ALLOW_POPUP_ERRORS=1
  ATOMOS_PHOSH_INTEGRATION_ALLOW_SESSION_RESTART=1
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
DIAG_SCRIPT="$ROOT_DIR/scripts/phosh/diagnose-phosh-home-chat-ui-crash.sh"
if [ ! -x "$DIAG_SCRIPT" ]; then
    echo "ERROR: missing executable $DIAG_SCRIPT" >&2
    exit 1
fi

SECONDS_WINDOW="${ATOMOS_PHOSH_INTEGRATION_SECONDS:-20}"
DIAG_OUT="${ATOMOS_PHOSH_DIAG_OUT_DIR:-$ROOT_DIR/build/phosh-diag-integration}"
ALLOW_POPUP_ERRORS="${ATOMOS_PHOSH_INTEGRATION_ALLOW_POPUP_ERRORS:-0}"
ALLOW_SESSION_RESTART="${ATOMOS_PHOSH_INTEGRATION_ALLOW_SESSION_RESTART:-0}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --seconds)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --seconds requires value" >&2; exit 2; }
            SECONDS_WINDOW="$1"
            ;;
        --diag-out)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --diag-out requires value" >&2; exit 2; }
            DIAG_OUT="$1"
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

mkdir -p "$DIAG_OUT"

echo "=== Phosh home chat integration test ==="
echo "profile_env=$PROFILE_ENV"
echo "ssh_target=$SSH_TARGET"
echo "window_seconds=$SECONDS_WINDOW"
echo "diag_out=$DIAG_OUT"

before_latest="$(ls -1dt "$DIAG_OUT"/* 2>/dev/null | head -n 1 || true)"
ATOMOS_PHOSH_DIAG_OUT_DIR="$DIAG_OUT" \
    bash "$DIAG_SCRIPT" "$PROFILE_ENV" "$SSH_TARGET" --seconds "$SECONDS_WINDOW"
after_latest="$(ls -1dt "$DIAG_OUT"/* 2>/dev/null | while read -r d; do [ -f "$d/summary.txt" ] && { echo "$d"; break; }; done | head -n 1 || true)"

if [ -z "$after_latest" ] || [ ! -d "$after_latest" ]; then
    echo "FAIL: diagnostics output directory with summary.txt not found." >&2
    exit 1
fi
if [ -n "$before_latest" ] && [ "$before_latest" = "$after_latest" ] && [ ! -f "$before_latest/summary.txt" ]; then
    # previous run wasn't valid; allow selecting the newest valid one.
    :
elif [ -n "$before_latest" ] && [ "$before_latest" = "$after_latest" ]; then
    echo "FAIL: diagnostics directory did not advance; expected new run." >&2
    exit 1
fi

echo "diag_run=$after_latest"

failures=0

count_matches_in_file() {
    local pattern="$1"
    local file="$2"
    if [ ! -f "$file" ]; then
        echo 0
        return 0
    fi
    (rg -n -i "$pattern" "$file" 2>/dev/null || true) | wc -l | tr -d '[:space:]'
}

require_file() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo "FAIL: missing diagnostics file: $f" >&2
        failures=$((failures + 1))
    fi
}

require_file "$after_latest/summary.txt"
require_file "$after_latest/since-marker-boot.log"
require_file "$after_latest/phosh-comm.log"
require_file "$after_latest/coredumps-filtered.log"
require_file "$after_latest/phosh-pid.txt"

if [ "$failures" -gt 0 ]; then
    echo "FAIL: required diagnostics artifacts missing." >&2
    exit 1
fi

if [ ! -s "$after_latest/phosh-pid.txt" ]; then
    echo "FAIL: phosh pid file is empty (phosh likely not running)." >&2
    failures=$((failures + 1))
fi

popup_err_total="$(count_matches_in_file "parent is not mapped|doesn't have a parent|Could not find application for app-id 'phosh'" \
    "$after_latest/since-marker-boot.log")"
if [ "$popup_err_total" -gt 0 ] && [ "$ALLOW_POPUP_ERRORS" != "1" ]; then
    echo "FAIL: detected popup/subsurface parent mapping errors ($popup_err_total)." >&2
    failures=$((failures + 1))
fi

session_restart_total="$(count_matches_in_file "Stopping User Manager for UID|Removed session [0-9]+|user@112.service: Deactivated successfully" \
    "$after_latest/since-marker-boot.log")"
if [ "$session_restart_total" -gt 0 ] && [ "$ALLOW_SESSION_RESTART" != "1" ]; then
    echo "FAIL: detected user-session teardown/restart markers ($session_restart_total)." >&2
    failures=$((failures + 1))
fi

phosh_core_total="$(count_matches_in_file "phosh.*(sigsegv|core|dumped)|sigsegv.*phosh|/usr/bin/phosh" \
    "$after_latest/coredumps-filtered.log")"
if [ "$phosh_core_total" -gt 0 ]; then
    echo "FAIL: detected phosh coredump markers ($phosh_core_total)." >&2
    failures=$((failures + 1))
fi

echo "--- Integration test summary ---"
echo "popup_parent_map_errors=$popup_err_total"
echo "session_restart_markers=$session_restart_total"
echo "phosh_coredump_markers=$phosh_core_total"
echo "diagnostics_dir=$after_latest"

if [ "$failures" -gt 0 ]; then
    echo "FAIL: phosh home chat integration checks failed ($failures)." >&2
    exit 1
fi

echo "PASS: phosh home chat integration checks passed."
