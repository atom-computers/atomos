#!/bin/bash
# Runtime smoke: after Phosh session is up, drive home unfold via D-Bus and assert
# atomos-overview-chat-ui is promoted to wlr-layer-shell overlay (visible on home).
#
# This complements static source contracts in:
#   rust/atomos-overview-chat-ui/core/tests/lifecycle_integration_contract.rs
#   rust/atomos-app-handler/core/tests/phosh_home_c_source_contract.rs
#
# Checks (on device via SSH):
#   - Phosh session + org.atomos.PhoshHome D-Bus
#   - SetFolded then SetUnfolded (same as manual swipe-up on home bar)
#   - chat-ui binary running with ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay in environ
#   - atomos-overview-chat-ui.log records overlay promotion (action=show / gtk_layer=Overlay)
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 bash scripts/overview-chat-ui/smoke-chat-ui-post-unlock.sh \
#     config/arm64-virt.env user@localhost
#
# Manual step: unlock the lockscreen when prompted (same as smoke-post-unlock.sh).
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    echo "Example: ATOMOS_DEVICE_SSH_PORT=2222 $0 config/arm64-virt.env user@localhost" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WAIT_SESSION_SEC="${ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC:-90}"
SETTLE_SEC="${ATOMOS_CHAT_UI_SMOKE_SETTLE_SEC:-4}"

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

POST_UNLOCK_RUNTIME_CHECKS="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"
CHAT_UI_SMOKE_CHECKS="$(cat "$ROOT_DIR/scripts/overview-chat-ui/_lib-chat-ui-smoke.remote.sh")"

REMOTE_SCRIPT="$(cat <<REMOTE_SH
set -u
fail=0
pass() { echo "PASS  \$1\${2:+ -- \$2}"; }
warn() { echo "FAIL  \$1 -- \$2"; fail=1; }
info() { echo "INFO  \$1 -- \$2"; }
header() { echo; echo "=== \$1 ==="; }

WAIT_SESSION_SEC="__WAIT_SESSION_SEC__"
ATOMOS_CHAT_UI_SMOKE_SETTLE_SEC="__SETTLE_SEC__"

__POST_UNLOCK_RUNTIME_CHECKS__

__CHAT_UI_SMOKE_CHECKS__

header "Prerequisites"
if [ ! -x /usr/local/bin/atomos-overview-chat-ui ]; then
    warn "chat-ui binary" "/usr/local/bin/atomos-overview-chat-ui missing"
else
    pass "chat-ui binary" "executable"
fi
if [ ! -x /usr/libexec/atomos-overview-chat-ui ]; then
    warn "chat-ui launcher" "/usr/libexec/atomos-overview-chat-ui missing"
else
    pass "chat-ui launcher" "executable"
fi
if strings /usr/libexec/phosh 2>/dev/null | grep -q 'atomos-overview-chat-ui'; then
    pass "phosh references chat-ui launcher" "strings match"
else
    warn "phosh references chat-ui launcher" "rebuild phosh with home.c lifecycle hooks"
fi

ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC="\$WAIT_SESSION_SEC"
TS_BEGIN="\$(date -Iseconds 2>/dev/null || date)"
info "journal baseline" "\$TS_BEGIN — unlock the device display now"
if ! atomos_smoke_wait_for_phosh_session; then
    fail=1
fi

if [ "\$fail" -eq 0 ]; then
    if ! atomos_chat_ui_smoke_drive_unfold_and_assert_overlay; then
        fail=1
    fi
fi

echo
if [ "\$fail" -eq 0 ]; then
    echo "RESULT: smoke-chat-ui-post-unlock PASS"
    exit 0
else
    echo "RESULT: smoke-chat-ui-post-unlock FAIL"
    echo "Hint: run scripts/app-handler/diagnose-app-handler.sh for static/runtime state."
    exit 1
fi
REMOTE_SH
)"

REMOTE_SCRIPT="${REMOTE_SCRIPT//__WAIT_SESSION_SEC__/$WAIT_SESSION_SEC}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__SETTLE_SEC__/$SETTLE_SEC}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__POST_UNLOCK_RUNTIME_CHECKS__/$POST_UNLOCK_RUNTIME_CHECKS}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__CHAT_UI_SMOKE_CHECKS__/$CHAT_UI_SMOKE_CHECKS}"

echo "smoke-chat-ui-post-unlock: connect to $SSH_TARGET (port $SSH_PORT)."
echo "Unlock the lockscreen on the device display now (waits up to ${WAIT_SESSION_SEC}s for phosh)."
echo "Then the script will SetFolded/SetUnfolded via D-Bus and check chat-ui layer=overlay."
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
