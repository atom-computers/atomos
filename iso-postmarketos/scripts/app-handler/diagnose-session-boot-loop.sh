#!/bin/bash
# Diagnose Phosh session crash loop after lockscreen unlock (QEMU/SSH).
#
# Use when smoke-post-unlock shows phosh missing and phoc pid keeps changing.
# Runs in ~5s on device; dumps process tree + journal — no 90s wait.
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 bash scripts/app-handler/diagnose-session-boot-loop.sh \
#     config/arm64-virt.env user@localhost
#
# Best moment: while the device is stuck re-loading after unlock.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
# shellcheck source=/dev/null
[ -f "$PROFILE_ENV_SOURCE" ] && source "$PROFILE_ENV_SOURCE"

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

REMOTE_LIB="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"

REMOTE_SCRIPT="$(cat <<REMOTE_SH
set -u
fail=0
pass() { echo "PASS  \$1\${2:+ -- \$2}"; }
warn() { echo "FAIL  \$1 -- \$2"; fail=1; }
info() { echo "INFO  \$1 -- \$2"; }
header() { echo; echo "=== \$1 ==="; }

${REMOTE_LIB}

TS_BEGIN="\$(date -Iseconds 2>/dev/null || date)"
info "ssh user" "\$(id -un 2>/dev/null || echo unknown) uid=\$(id -u 2>/dev/null || echo ?)"

atomos_diagnose_session_kind

header "OpenRC / seat stack"
for svc in seatd elogind dbus greetd phoc; do
    if rc-status 2>/dev/null | grep -q "^\${svc}"; then
        info "rc-status" "\$(rc-status 2>/dev/null | grep \"^\${svc}\" | head -n1 | tr -s ' ')"
    elif [ -x "/etc/init.d/\${svc}" ]; then
        info "/etc/init.d/\${svc}" "\$(/etc/init.d/\${svc} status 2>&1 | head -n1 | tr -d '\n')"
    else
        info "\${svc}" "no openrc entry"
    fi
done

header "Process snapshot"
_ps="\$(ps -eo pid,ppid,user,comm,args 2>/dev/null | grep -Ei 'phoc|phosh|gnome-session|greetd|atomos-app-handler|phosh-session' | grep -v grep || true)"
if [ -n "\$_ps" ]; then
    echo "\$_ps"
else
    warn "process list" "no phoc/phosh/gnome-session lines in ps"
fi

phosh_pid="\$(atomos_find_phosh_pid)"
phoc_pid="\$(atomos_find_phoc_pid)"
if [ -n "\$phosh_pid" ]; then pass "phosh pid" "\$phosh_pid"; else warn "phosh pid" "missing"; fi
if [ -n "\$phoc_pid" ]; then pass "phoc pid" "\$phoc_pid"; else warn "phoc pid" "missing"; fi
atomos_detect_graphical_runtime && pass "XDG_RUNTIME_DIR" "\$ATOMOS_SESSION_RUN" || warn "XDG_RUNTIME_DIR" "no wayland socket"

header "phosh-profile + autostart"
atomos_post_unlock_check_phosh_profile_env_readable
if [ -f /etc/xdg/autostart/atomos-app-handler.desktop ]; then
    pass "handler autostart" "present"
    grep '^Exec=' /etc/xdg/autostart/atomos-app-handler.desktop 2>/dev/null || true
else
    warn "handler autostart" "missing"
fi

for log in /run/user/*/atomos-app-handler.log; do
    [ -f "\$log" ] || continue
    info "handler log" "\$log (last 25 lines)"
    tail -n 25 "\$log" 2>/dev/null || true
done

atomos_dump_session_journal_snippet "\$TS_BEGIN"

echo
if [ "\$fail" -eq 0 ]; then
    echo "RESULT: diagnose-session-boot-loop PASS (processes look up — if UI still loops, journal above is the lead)"
    exit 0
else
    echo "RESULT: diagnose-session-boot-loop FAIL — fix phosh/phoc/greetd lines above, then re-run smoke"
    exit 1
fi
REMOTE_SH
)"

echo "diagnose-session-boot-loop: $SSH_TARGET (port $SSH_PORT)"
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
