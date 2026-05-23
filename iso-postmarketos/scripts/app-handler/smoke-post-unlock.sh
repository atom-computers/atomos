#!/bin/bash
# Gate (2): runtime smoke after lockscreen unlock on a running device/QEMU.
#
# Checks:
#   - phosh + atomos-app-handler (+ optional home-bg) processes up
#   - org.atomos.PhoshHome on the session bus + GetState/SetUnfolded round-trip
#   - stack contract markers match on disk
#   - phosh binary contains org.atomos.PhoshHome (not stock phosh)
#   - handler log must not show cold SIGUSR1 open right after session start
#   - journalctl: no phoc/session "permission denied" or crash hints since unlock
#   - phoc compositor pid stable; phosh-profile.env readable by session
#   - phosh pid alive across WATCH_SECONDS hold window
#     (parity with tests/integration/test_qemu_phosh_login_lifetime.py: catches
#     the post-login crash class that brought down QEMU on macOS)
#   - dmesg + /var/log/messages clean of virtio_gpu / GPU reset / phosh segfault
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 bash scripts/app-handler/smoke-post-unlock.sh config/arm64-virt.env user@localhost
#
# Manual step: unlock the lockscreen when prompted, then wait for the watch window.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    echo "Example: ATOMOS_DEVICE_SSH_PORT=2222 $0 config/arm64-virt.env user@localhost" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCH_SECONDS="${ATOMOS_SMOKE_WATCH_SECONDS:-25}"
WAIT_SESSION_SEC="${ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC:-90}"
STACK_VERSION="${ATOMOS_STACK_INTEGRATION_VERSION:-app-handler-v1-launch-switcher-dbus-home}"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
    echo "ssh and sshpass are required." >&2
    exit 1
fi

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR)

REMOTE_SCRIPT="$(cat <<REMOTE_SH
set -u
fail=0
pass() { echo "PASS  \$1\${2:+ -- \$2}"; }
warn() { echo "FAIL  \$1 -- \$2"; fail=1; }
info() { echo "INFO  \$1 -- \$2"; }
header() { echo; echo "=== \$1 ==="; }

STACK_VERSION="__STACK_VERSION__"
WATCH_SECONDS="__WATCH_SECONDS__"
WAIT_SESSION_SEC="__WAIT_SESSION_SEC__"

header "Stack integration contract markers"
if [ -f /etc/atomos/app-handler-contract ] && [ -f /etc/atomos/phosh-integration-contract ]; then
    hv="\$(cat /etc/atomos/app-handler-contract | tr -d '[:space:]')"
    pv="\$(cat /etc/atomos/phosh-integration-contract | tr -d '[:space:]')"
    if [ "\$hv" = "\$STACK_VERSION" ] && [ "\$pv" = "\$STACK_VERSION" ]; then
        pass "contract markers match" "\$STACK_VERSION"
    else
        warn "contract markers mismatch" "handler=\$hv phosh=\$pv expected=\$STACK_VERSION"
    fi
else
    warn "contract marker files" "missing app-handler-contract or phosh-integration-contract"
fi

header "Phosh binary includes AtomOS D-Bus (not stock phosh)"
if [ -x /usr/libexec/phosh ]; then
    if strings /usr/libexec/phosh 2>/dev/null | grep -q 'org.atomos.PhoshHome'; then
        pass "strings /usr/libexec/phosh" "org.atomos.PhoshHome present"
    else
        warn "strings /usr/libexec/phosh" "missing org.atomos.PhoshHome — image may ship stock phosh"
    fi
else
    warn "/usr/libexec/phosh" "missing or not executable"
fi

__POST_UNLOCK_RUNTIME_CHECKS__

ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC="\$WAIT_SESSION_SEC"
TS_BEGIN="\$(date -Iseconds 2>/dev/null || date)"
ATOMOS_BASELINE_TS="\$TS_BEGIN"
info "journal baseline" "\$TS_BEGIN (unlock on device now; scanning journal from this point)"
if ! atomos_smoke_wait_for_phosh_session; then
    fail=1
fi
info "post-wait journal" "continuing checks (TS_BEGIN=\$TS_BEGIN)"
atomos_post_unlock_capture_baseline

header "Session processes (graphical session)"
phosh_pid="\$(atomos_find_phosh_pid)"
handler_pids="\$(atomos_find_handler_pids)"
if [ -n "\$phosh_pid" ]; then pass "phosh running" "pid=\$phosh_pid"; else warn "phosh running" "no pid"; fi
if [ -n "\$handler_pids" ]; then
    pass "atomos-app-handler running" "pid(s)=\$handler_pids"
else
    warn "atomos-app-handler running" "no pid — check autostart and /etc/xdg/autostart/atomos-app-handler.desktop"
fi
if atomos_detect_graphical_runtime; then
    pass "graphical XDG_RUNTIME_DIR" "\$ATOMOS_SESSION_RUN (uid \$ATOMOS_SESSION_UID)"
else
    warn "graphical XDG_RUNTIME_DIR" "no wayland socket under /run/user/*"
fi

header "org.atomos.PhoshHome D-Bus (Phosh session bus, not SSH login bus)"
if command -v busctl >/dev/null 2>&1; then
    atomos_detect_graphical_runtime || true
    if [ -n "\${ATOMOS_SESSION_DBUS:-}" ]; then
        info "session bus" "\$ATOMOS_SESSION_DBUS"
    fi
    if atomos_session_busctl status org.atomos.PhoshHome >/dev/null 2>&1; then
        pass "busctl status org.atomos.PhoshHome"
        state="\$(atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome GetState 2>/dev/null | awk '{print \$2}' | tr -d '\"' || true)"
        info "GetState" "\${state:-<empty>}"
        if atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome SetUnfolded >/dev/null 2>&1; then
            pass "busctl SetUnfolded"
        else
            warn "busctl SetUnfolded" "call failed"
        fi
        if atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome SetFolded >/dev/null 2>&1; then
            pass "busctl SetFolded"
        else
            warn "busctl SetFolded" "call failed"
        fi
    else
        warn "busctl status org.atomos.PhoshHome" "not on Phosh session bus (phosh crashed or D-Bus not exported?)"
    fi
else
    warn "busctl" "not installed"
fi

header "Handler must not auto-open switcher overlay on unlock"
echo "Watching handler log for \${WATCH_SECONDS}s — FAIL if SIGUSR1/opening switcher without user swipe..."
log=""
if [ -n "\${ATOMOS_SESSION_RUN:-}" ] && [ -f "\${ATOMOS_SESSION_RUN}/atomos-app-handler.log" ]; then
    log="\${ATOMOS_SESSION_RUN}/atomos-app-handler.log"
fi
if [ -z "\$log" ]; then
    for f in /run/user/*/atomos-app-handler.log; do
        [ -f "\$f" ] && log="\$f" && break
    done
fi
if [ -z "\$log" ]; then
    warn "handler log" "no /run/user/*/atomos-app-handler.log"
else
    start_lines="\$(wc -l < "\$log" | tr -d ' ')"
    sleep "\$WATCH_SECONDS"
    if tail -n 80 "\$log" 2>/dev/null | grep -qE 'SIGUSR1 received|opening switcher overlay|action=show'; then
        warn "handler log after unlock" "switcher opened without swipe (see \$log)"
        tail -n 20 "\$log" 2>/dev/null || true
    else
        pass "handler log after unlock" "no unsolicited SIGUSR1/open in last 80 lines"
    fi
fi

atomos_post_unlock_check_phosh_profile_env_readable
atomos_post_unlock_check_phoc_process_stable
atomos_post_unlock_check_phoc_journal_since "\$TS_BEGIN"
atomos_post_unlock_check_phosh_runtime_hold "\$WATCH_SECONDS"
atomos_post_unlock_check_gpu_segfault_dmesg

echo
if [ "\$fail" -eq 0 ]; then
    echo "RESULT: smoke-post-unlock PASS"
    exit 0
else
    echo "RESULT: smoke-post-unlock FAIL"
    exit 1
fi
REMOTE_SH
)"

POST_UNLOCK_RUNTIME_CHECKS="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__STACK_VERSION__/$STACK_VERSION}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__WATCH_SECONDS__/$WATCH_SECONDS}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__WAIT_SESSION_SEC__/$WAIT_SESSION_SEC}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__POST_UNLOCK_RUNTIME_CHECKS__/$POST_UNLOCK_RUNTIME_CHECKS}"

echo "smoke-post-unlock: connect to $SSH_TARGET (port $SSH_PORT)."
echo "Unlock the lockscreen on the device display now (script waits up to ${WAIT_SESSION_SEC}s for phosh)."
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
