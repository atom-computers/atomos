#!/bin/bash
# Bisect the post-login Phosh SIGSEGV by toggling the runtime knobs.
#
# Symptom this script splits:
#   gnome-session-binary[N]: WARNING: Application 'mobi.phosh.Shell.desktop'
#     killed by signal 11
#   gnome-session-binary[N]: ... Unrecoverable failure in required component
#     mobi.phosh.Shell.desktop
#
# Procedure:
#   1. Use scripts/app-handler/_lib-remote-elevate.sh to elevate over SSH
#      (doas -n if /etc/doas.conf has the lock-parity nopass rule, else
#      sudo -S, else expect + ssh -tt feeding the password to doas).
#   2. Rewrite /etc/atomos/phosh-profile.env with all runtime knobs OFF:
#        ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=0
#        ATOMOS_APP_HANDLER_TAKES_OVER=0
#        ATOMOS_APP_HANDLER_ENABLE_RUNTIME=0
#      The phosh C patches are still compiled into the binary, but their
#      runtime branches that spawn /usr/libexec/atomos-app-handler, hide
#      PhoshOverview, and claim the bottom-edge drag never execute.
#   3. (Optional) Remove /etc/xdg/autostart/atomos-app-handler.desktop so
#      the layer-shell handler also never opens.
#   4. Restart greetd so phrog and phosh re-exec with the new env.
#   5. Poll greetd / phoc / phosh pids for HOLD_SECONDS (default 30s) and
#      grep /var/log/messages for "killed by signal" lines.
#   6. Print a verdict:
#        * phosh stays alive   -> cause is in the RUNTIME-gated phosh
#                                 patches; bisect by re-enabling knobs
#                                 one at a time.
#        * phosh still dies    -> cause is in the ALWAYS-ON phosh patches.
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 \
#   bash iso-postmarketos/scripts/app-handler/bisect-phosh-runtime-knobs.sh \
#     iso-postmarketos/config/arm64-virt.env user@localhost
#
# Env knobs:
#   ATOMOS_BISECT_HOLD_SECONDS                poll window length (default 30)
#   ATOMOS_BISECT_REVERT_ON_EXIT              restore original env on exit (default 0)
#   ATOMOS_BISECT_DISABLE_HANDLER_AUTOSTART   also nuke handler autostart (default 1)
#   ATOMOS_DEVICE_SSH_PORT, ATOMOS_DEVICE_SSHPASS — same as other diag scripts
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
HOLD_SECONDS="${ATOMOS_BISECT_HOLD_SECONDS:-30}"
REVERT_ON_EXIT="${ATOMOS_BISECT_REVERT_ON_EXIT:-0}"
DISABLE_HANDLER_AUTOSTART="${ATOMOS_BISECT_DISABLE_HANDLER_AUTOSTART:-1}"

export ATOMOS_DEVICE_SSH_PORT="$SSH_PORT"
REMOTE_SUDO_PASSWORD="$SSH_PASSWORD"
export REMOTE_SUDO_PASSWORD

SSH_OPTS=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" "${SSH_OPTS[@]}")
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" "${SSH_OPTS[@]}")

# shellcheck source=_lib-remote-elevate.sh
source "$ROOT_DIR/scripts/app-handler/_lib-remote-elevate.sh"

echo "bisect-phosh-runtime-knobs: $SSH_TARGET (port $SSH_PORT)"
echo "  hold window: ${HOLD_SECONDS}s   disable handler autostart: ${DISABLE_HANDLER_AUTOSTART}   revert on exit: ${REVERT_ON_EXIT}"

# ── Phase 1: pre-state report (unprivileged SSH) ─────────────────────────
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<'PRESTATE'
printf '\n=== Pre-state ===\n'
printf 'INFO  begin           -- %s\n' "$(date -Iseconds 2>/dev/null || date)"
printf 'INFO  ssh uid         -- %s (%s)\n' "$(id -u 2>/dev/null)" "$(id -un 2>/dev/null)"
if [ -r /etc/atomos/phosh-profile.env ]; then
    printf 'INFO  env file (before)\n'
    sed 's/^/    /' /etc/atomos/phosh-profile.env | head -n 20
else
    printf 'FAIL  env file       -- /etc/atomos/phosh-profile.env not readable\n'
fi
if [ -f /etc/xdg/autostart/atomos-app-handler.desktop ]; then
    printf 'INFO  handler autostart -- present\n'
else
    printf 'INFO  handler autostart -- already absent\n'
fi
PRESTATE

# ── Phase 2: apply neuter overlay via elevation ──────────────────────────
echo ""
echo "=== Apply neuter overlay ==="

NEUTER_REMOTE_BODY=$(cat <<NEUTER_EOF
set -eu
ENV_FILE=/etc/atomos/phosh-profile.env
ENV_BACKUP=/tmp/phosh-profile.env.before-bisect
HANDLER_AUTOSTART=/etc/xdg/autostart/atomos-app-handler.desktop
HANDLER_BACKUP=/tmp/atomos-app-handler.desktop.before-bisect

if [ -f "\$ENV_FILE" ]; then
    cp "\$ENV_FILE" "\$ENV_BACKUP"
    echo "backup: \$ENV_FILE -> \$ENV_BACKUP"
fi
install -d /etc/atomos
cat > "\$ENV_FILE" << "INNER_EOF"
# AtomOS bisect snapshot: all runtime branches OFF.
# Restore from /tmp/phosh-profile.env.before-bisect to undo.
ATOMOS_UI_PROFILE=phosh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=0
ATOMOS_APP_HANDLER_TAKES_OVER=0
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=0
INNER_EOF
chmod 0644 "\$ENV_FILE"
echo "rewrote: \$ENV_FILE"

if [ "$DISABLE_HANDLER_AUTOSTART" = "1" ] && [ -f "\$HANDLER_AUTOSTART" ]; then
    cp "\$HANDLER_AUTOSTART" "\$HANDLER_BACKUP" 2>/dev/null || true
    rm -f "\$HANDLER_AUTOSTART"
    echo "removed: \$HANDLER_AUTOSTART (backup at \$HANDLER_BACKUP)"
fi

if command -v rc-service >/dev/null 2>&1; then
    rc-service greetd restart 2>&1 | head -n 3
elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart greetd 2>&1 | head -n 3
else
    echo "greetd: no rc-service or systemctl; cannot restart" >&2
fi
NEUTER_EOF
)

if atomos_remote_run_elevated "$SSH_TARGET" "$NEUTER_REMOTE_BODY"; then
    echo "PASS  neuter overlay applied"
else
    echo "FAIL  neuter overlay could not be applied via doas / sudo / expect" >&2
    echo "      Fix: rebuild image (apply-overlay.sh now writes /etc/doas.conf), or:" >&2
    echo "        ssh -tt -p $SSH_PORT $SSH_TARGET 'doas tee /etc/atomos/phosh-profile.env'" >&2
    exit 1
fi

# ── Phase 3: hold window — poll phosh / phoc / gnome-session ─────────────
echo ""
echo "=== Hold window (${HOLD_SECONDS}s) ==="

REMOTE_LIB="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"

REMOTE_PROLOGUE=$(printf '%s\n' "HOLD_SECONDS=${HOLD_SECONDS}")

REMOTE_BODY=$(cat <<'REMOTE_SH'
set -u

pass()   { printf 'PASS  %s%s\n' "$1" "${2:+ -- $2}"; }
warn()   { printf 'FAIL  %s -- %s\n' "$1" "${2:-}"; }
info()   { printf 'INFO  %s -- %s\n' "$1" "${2:-}"; }
header() { printf '\n=== %s ===\n' "$1"; }

__REMOTE_LIB__

TS_BEGIN_ISO="$(date -Iseconds 2>/dev/null || date)"
info "hold begin" "$TS_BEGIN_ISO"

phosh_seen=0
phosh_alive_at_end=0
sigsegv_lines=0
last_phosh_pid=""

waited=0
while [ "$waited" -lt "$HOLD_SECONDS" ]; do
    pid="$(atomos_find_phosh_pid)"
    if [ -n "$pid" ]; then
        phosh_seen=1
        if [ "$pid" != "$last_phosh_pid" ]; then
            info "phosh seen" "pid=$pid (t+${waited}s)"
            last_phosh_pid="$pid"
        fi
    fi
    sleep 2
    waited=$((waited + 2))
done

final_pid="$(atomos_find_phosh_pid)"
[ -n "$final_pid" ] && phosh_alive_at_end=1

sigsegv_examples=""
if [ -r /var/log/messages ]; then
    sigsegv_examples="$(grep -E "Application 'mobi\\.phosh\\.Shell\\.desktop' killed by signal|Unrecoverable failure in required component mobi\\.phosh\\.Shell\\.desktop" /var/log/messages 2>/dev/null | tail -n 8 || true)"
    [ -n "$sigsegv_examples" ] && sigsegv_lines="$(printf '%s\n' "$sigsegv_examples" | wc -l | tr -d ' ')"
fi

header "Result"
info "phosh ever seen"      "$phosh_seen"
info "phosh alive at end"   "$phosh_alive_at_end (final pid=${final_pid:-<none>})"
info "SIGSEGV markers"      "$sigsegv_lines line(s) in /var/log/messages"
if [ -n "$sigsegv_examples" ]; then
    printf '%s\n' "$sigsegv_examples" | tail -n 6 | sed 's/^/    /'
fi

header "Verdict"
if [ "$phosh_alive_at_end" = "1" ] && [ "$sigsegv_lines" = "0" ]; then
    pass "verdict" "phosh stayed up with all knobs OFF"
    info "next step" "the SIGSEGV is in a RUNTIME-gated phosh patch"
    info "narrow" "re-enable one knob at a time:"
    info "  step 1" "ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1, others 0  -> phosh dies? home.c bottom-edge drag claim"
    info "  step 2" "ATOMOS_APP_HANDLER_TAKES_OVER=1,         others 0  -> phosh dies? overview.c force-hide / app-grid spawn"
    info "  step 3" "ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1,      others 0 -> phosh dies? home.c sync_app_handler_lifecycle spawn"
else
    warn "verdict" "phosh still dies with all knobs OFF"
    info "next step" "the SIGSEGV is in an ALWAYS-ON phosh patch (not env-gated)"
    info "candidates"
    info "  always-on 1" "overview.c: phosh_overview_set_running_activities_visible(self, FALSE) in phosh_overview_init"
    info "  always-on 2" "shell.c: atomos_phosh_home_dbus_set_exported(TRUE) from setup_idle_cb"
    info "  always-on 3" "shell.c: phosh_shell_get_usable_area drops PHOSH_HOME_BAR_HEIGHT"
    info "  always-on 4" "shell.c: on_num_toplevels_changed + on_toplevel_added stubbed"
    info "  always-on 5" "toplevel-manager.c: toplevels_ignored array removed"
    info "  always-on 6" "top-panel.c: drag-mode PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE added"
fi
REMOTE_SH
)

REMOTE_LIB_TMP="$(mktemp)"
trap 'rm -f "$REMOTE_LIB_TMP"' EXIT
printf '%s\n' "$REMOTE_LIB" > "$REMOTE_LIB_TMP"

REMOTE_BODY_INLINED="$(awk -v libfile="$REMOTE_LIB_TMP" '
    /^__REMOTE_LIB__$/ {
        while ((getline line < libfile) > 0) print line
        close(libfile)
        next
    }
    { print }
' <<<"$REMOTE_BODY")"

"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
${REMOTE_PROLOGUE}
${REMOTE_BODY_INLINED}
EOF

# ── Phase 4: optional revert ─────────────────────────────────────────────
if [ "$REVERT_ON_EXIT" = "1" ]; then
    echo ""
    echo "=== Revert ==="
    REVERT_BODY="$(cat <<'REVERT_EOF'
set -eu
if [ -f /tmp/phosh-profile.env.before-bisect ]; then
    cp /tmp/phosh-profile.env.before-bisect /etc/atomos/phosh-profile.env
    chmod 0644 /etc/atomos/phosh-profile.env
    echo "restored: /etc/atomos/phosh-profile.env"
fi
if [ -f /tmp/atomos-app-handler.desktop.before-bisect ]; then
    cp /tmp/atomos-app-handler.desktop.before-bisect /etc/xdg/autostart/atomos-app-handler.desktop
    chmod 0644 /etc/xdg/autostart/atomos-app-handler.desktop
    echo "restored: /etc/xdg/autostart/atomos-app-handler.desktop"
fi
if command -v rc-service >/dev/null 2>&1; then
    rc-service greetd restart 2>&1 | head -n 3
elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart greetd 2>&1 | head -n 3
fi
REVERT_EOF
    )"
    if atomos_remote_run_elevated "$SSH_TARGET" "$REVERT_BODY"; then
        echo "PASS  reverted"
    else
        echo "FAIL  revert could not run; manual fix:"
        echo "      ssh -tt -p $SSH_PORT $SSH_TARGET 'doas cp /tmp/phosh-profile.env.before-bisect /etc/atomos/phosh-profile.env && doas rc-service greetd restart'"
    fi
fi
