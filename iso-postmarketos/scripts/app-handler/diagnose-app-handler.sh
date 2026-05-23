#!/bin/bash
# Diagnose the atomos-app-handler swipe-up pipeline on a running device.
#
# Walks every link in the chain — files installed, env wired, process up,
# launcher log, phosh env, layer-shell globals — and prints one PASS/FAIL
# line per check. Mirrors the SSH plumbing in
# `scripts/app-handler/hotfix-app-handler.sh` so QEMU users with
#   ssh -p 2222 user@localhost
# can run it unchanged.
#
# Usage:
#   bash scripts/app-handler/diagnose-app-handler.sh <profile-env> <ssh-target>
#
# Environment knobs (same as hotfix):
#   ATOMOS_DEVICE_SSH_PORT (default 22; set to 2222 for the QEMU image)
#   ATOMOS_DEVICE_SSHPASS / SSHPASS / PMOS_INSTALL_PASSWORD (default 147147)
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    echo "Example: $0 config/arm64-virt.env user@localhost  (with ATOMOS_DEVICE_SSH_PORT=2222)" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
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

if ! command -v ssh >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
    echo "ssh and sshpass are required." >&2
    exit 1
fi

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR)

# Remote diagnose script — runs inside /bin/sh on the device. Each check
# prints one of:
#   PASS  <check name>     [-- <extra context>]
#   FAIL  <check name>     -- <reason>
#   INFO  <check name>     -- <data>
# The exit code reflects whether any FAIL fired so CI / Make targets can
# gate on it. Keep this script POSIX-shell friendly — Alpine's busybox /bin/sh
# does not have bash-isms.
REMOTE_SCRIPT='
set -u
fail=0
pass() { echo "PASS  $1${2:+ -- $2}"; }
warn() { echo "FAIL  $1 -- $2"; fail=1; }
info() { echo "INFO  $1 -- $2"; }
header() { echo; echo "=== $1 ==="; }

# ----- Files installed -----
header "Files installed by install-app-handler.sh"
for p in /usr/local/bin/atomos-app-handler /usr/bin/atomos-app-handler /usr/libexec/atomos-app-handler; do
    if [ -x "$p" ]; then pass "executable $p"; else warn "executable $p" "missing or not +x"; fi
done
if [ -f /etc/atomos/app-handler-contract ]; then
    pass "/etc/atomos/app-handler-contract present"
    if grep -q "^app-handler-v1-launch-switcher-dbus-home$" /etc/atomos/app-handler-contract; then
        pass "app-switcher hybrid lifecycle contract marker"
    else
        warn "app-switcher hybrid lifecycle contract marker" "expected app-handler-v1-launch-switcher-dbus-home"
    fi
else
    warn "/etc/atomos/app-handler-contract" "missing"
fi
if [ -f /etc/xdg/autostart/atomos-app-handler.desktop ]; then
    pass "/etc/xdg/autostart/atomos-app-handler.desktop present"
    if grep -q "^Exec=/usr/libexec/atomos-app-handler --start$" /etc/xdg/autostart/atomos-app-handler.desktop; then
        pass "handle-bar autostart Exec= contract"
    else
        warn "handle-bar autostart Exec= contract" "expected: Exec=/usr/libexec/atomos-app-handler --start"
    fi
else
    warn "/etc/xdg/autostart/atomos-app-handler.desktop" "missing; no visible swipe-up bar at login"
fi

# Locate the phosh process (the shell, not phoc the compositor) under
# several common process name shapes for optional diagnostics.
find_phosh_pid() {
    # Locate the phosh process under several common process name shapes.
    # The whole REMOTE_SCRIPT is single-quoted at the local shell level,
    # so we cannot use literal single quotes inside the patterns; use
    # double-quoted patterns with backslash-escaped dollar signs so the
    # local heredoc passes them through unchanged to the remote shell.
    #
    # 1. Strict comm match -- works on stock upstream builds.
    pid="$(pgrep -x phosh 2>/dev/null | head -n1 || true)"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    # 2. Alpine wrapper: actual ELF named phosh.real, comm follows.
    pid="$(pgrep -x phosh.real 2>/dev/null | head -n1 || true)"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    # 3. Command-line match on the canonical install path.
    pid="$(pgrep -f "^/usr/bin/phosh( |\$)" 2>/dev/null | head -n1 || true)"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    # 4. Last-resort: any command line containing /phosh anchored on a
    #    boundary, so phosh-mobile-settings / phosh-osk-stub / libphosh
    #    consumers do not produce false positives.
    pid="$(pgrep -f "(^|/)phosh(\$|[[:space:]])" 2>/dev/null | head -n1 || true)"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    echo ""
}

header "Launcher lifecycle / signal bridge"
if [ -x /usr/libexec/atomos-app-handler ]; then
    for pat in action=show action=hide signal_show signal_hide "kill -USR1" "kill -USR2"; do
        if grep -q "$pat" /usr/libexec/atomos-app-handler; then
            pass "launcher has \"$pat\" path"
        else
            warn "launcher has \"$pat\" path" "missing from /usr/libexec/atomos-app-handler"
        fi
    done
fi

header "phosh process presence"
phosh_pid="$(find_phosh_pid)"
if [ -z "$phosh_pid" ]; then
    # Print the candidate comm names we tried so the user can quickly tell
    # whether phosh is missing entirely vs running under an unexpected name.
    # No inner single quotes -- the whole REMOTE_SCRIPT is single-quoted
    # at the local shell level; use grep + sed instead of awk to stay
    # double-quote-only.
    comms="$(ps -eo pid,comm 2>/dev/null | grep -i phosh | sed "s/^[[:space:]]*//" | tr "\n" " " || true)"
    info "phosh process" "no phosh process matched (tried: phosh, phosh.real, /usr/bin/phosh, *phosh*). ps grep: ${comms:-<none>}"
else
    pass "phosh pid" "$phosh_pid"
fi

# ----- Runtime library dependencies (ldd) -----
header "Runtime library deps (ldd)"
if command -v ldd >/dev/null 2>&1 && [ -x /usr/local/bin/atomos-app-handler ]; then
    missing="$(ldd /usr/local/bin/atomos-app-handler 2>&1 | grep -i "not found" || true)"
    if [ -z "$missing" ]; then
        pass "ldd /usr/local/bin/atomos-app-handler" "no missing libraries"
    else
        warn "ldd /usr/local/bin/atomos-app-handler" "missing: $missing"
    fi
else
    info "ldd" "ldd unavailable or binary missing; skipping"
fi
for lib in libgtk-4 libgtk4-layer-shell libwayland-client; do
    found="$(find /usr/lib /usr/local/lib /lib -maxdepth 4 -name "${lib}*" 2>/dev/null | head -n 1 || true)"
    if [ -n "$found" ]; then pass "library present" "$lib -> $found"; else warn "library present" "$lib missing in /usr/lib /usr/local/lib /lib"; fi
done

# ----- Process state -----
header "Process / runtime state"
APP_SWITCHER_PIDS="$(pgrep -f "/usr/local/bin/atomos-app-handler" 2>/dev/null || true)"
PHOSH_PID="$(find_phosh_pid)"
if [ -n "$APP_SWITCHER_PIDS" ]; then
    pass "atomos-app-handler running (handle bar)" "pid(s): $APP_SWITCHER_PIDS"
else
    warn "atomos-app-handler running (handle bar)" "no process; the visible swipe-up bar will be missing"
fi
if [ -n "$PHOSH_PID" ]; then
    pass "phosh running" "pid $PHOSH_PID"
else
    info "phosh running" "no phosh process"
fi

# ----- Env var visibility -----
header "Env var visibility (proc/<pid>/environ)"
if [ -n "$APP_SWITCHER_PIDS" ]; then
    AS_PID="$(echo "$APP_SWITCHER_PIDS" | head -n 1)"
    if [ -r "/proc/$AS_PID/environ" ]; then
        env_dump="$(tr "\000" "\n" < "/proc/$AS_PID/environ" | grep -E "^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|GDK_BACKEND|ATOMOS_APP_HANDLER_)" | tr "\n" " ")"
        info "app-switcher env" "${env_dump:-<no relevant vars>}"
        if echo "$env_dump" | grep -q "ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1"; then
            pass "app-switcher sees ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1"
        else
            warn "app-switcher sees ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1" "binary will exit early without presenting a surface"
        fi
        if echo "$env_dump" | grep -q "WAYLAND_DISPLAY="; then
            pass "app-switcher sees WAYLAND_DISPLAY"
        else
            warn "app-switcher sees WAYLAND_DISPLAY" "binary cannot connect to the compositor"
        fi
    fi
else
    info "app-switcher env" "process not running; the launcher --show signal will start it"
fi

# ----- Lifecycle hook evidence in the launcher log -----
header "Lifecycle hook evidence (launcher log)"
saw_show=0
saw_hide=0
for log in /run/user/*/atomos-app-handler.log; do
    [ -f "$log" ] || continue
    if grep -q "action=show" "$log"; then saw_show=1; fi
    if grep -q "action=hide" "$log"; then saw_hide=1; fi
done
if [ "$saw_show" = "1" ]; then
    pass "launcher log records action=show"
else
    info "launcher log records action=show" "no --show event observed yet (unfold the home to fire it)"
fi
if [ "$saw_hide" = "1" ]; then
    pass "launcher log records action=hide"
else
    info "launcher log records action=hide" "no --hide event observed yet (fold the home to fire it)"
fi

# ----- Disable marker -----
header "Disable markers (launcher self-disable on rc=127)"
disabled="$(ls /run/user/*/atomos-app-handler.disabled 2>/dev/null || true)"
if [ -z "$disabled" ]; then
    pass "no disable marker present"
else
    warn "launcher disable marker present" "$disabled (delete to re-enable; usually means binary exited rc=127, i.e. missing shared lib)"
fi

# ----- Launcher log -----
# The REMOTE_SCRIPT runs under /bin/sh -u; the launcher writes the log
# into $XDG_RUNTIME_DIR/atomos-app-handler.log on the phosh user but
# the ssh session itself may not export XDG_RUNTIME_DIR (especially for
# root-flavoured logins on the QEMU image). Use a glob-style default in
# the header purely as banner text; the real scan below loops over
# /run/user/* directly so XDG_RUNTIME_DIR being unset is a non-issue.
header "Launcher log (last 60 lines of ${XDG_RUNTIME_DIR:-/run/user/*}/atomos-app-handler.log)"
for log in /run/user/*/atomos-app-handler.log; do
    if [ -f "$log" ]; then
        info "log path" "$log"
        echo "----8<----"
        tail -n 60 "$log" || true
        echo "----8<----"
    fi
done

# ----- Gesture pipeline analysis -----
# Reads the latest session slice of the launcher log and classifies *which*
# stage of the swipe-up pipeline is failing. This is the diagnostic you
# want when the visible bar is there but "swipe up does nothing":
#
#   1. handle_window mapped?            → wayland surface is up
#   2. handle_strip resize fired?       → GTK allocated the strip
#   3. event_probe count > 0?           → touches reach the widget
#   4. drag_begin count > 0?            → GestureDrag started
#   5. drag_update count > 0?           → motion events flow
#   6. accumulated_dy ever ≥ 48 px?     → threshold reachable
#   7. outcome=OpenOverlay seen?        → evaluator agreed
#   8. overlay open from= seen?         → state machine accepted
#
# A single "FAIL  swipe pipeline" line points at the most-upstream gap
# so the user knows whether to look at Phoc/Phosh, GTK, or the gesture
# threshold.
header "Gesture pipeline analysis (latest atomos-app-handler session)"
LOG=""
for log in /run/user/*/atomos-app-handler.log; do
    [ -f "$log" ] && LOG="$log"
done
if [ -z "$LOG" ]; then
    info "gesture pipeline" "no launcher log yet — open an app and swipe up, then re-run"
else
    last_startup_lineno="$(grep -n "atomos-app-handler: startup pid=" "$LOG" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)"
    if [ -n "$last_startup_lineno" ]; then
        SLICE="$(tail -n +"$last_startup_lineno" "$LOG" 2>/dev/null || cat "$LOG")"
    else
        SLICE="$(cat "$LOG")"
    fi

    map_line="$(printf "%s\n" "$SLICE" | grep -m 1 "handle_window map width=" || true)"
    if [ -n "$map_line" ]; then
        pass "handle_window mapped" "${map_line##*atomos-app-handler: }"
        map_w="$(printf "%s\n" "$map_line" | sed -n "s/.* width=\([0-9][0-9]*\).*/\1/p")"
        if [ -n "$map_w" ] && [ "$map_w" -lt 360 ]; then
            warn "handle_window width" "${map_w}px < 360 — layer-shell L+R anchors may not be honored; touches outside this strip will miss"
        fi
    else
        info "handle_window mapped" "no map line in this session — open an app to trigger toplevel_count > 0"
    fi

    resize_line="$(printf "%s\n" "$SLICE" | grep -m 1 "handle_strip resize" || true)"
    if [ -n "$resize_line" ]; then
        pass "handle_strip allocated" "${resize_line##*atomos-app-handler: }"
    fi

    probe_count="$(printf "%s\n" "$SLICE" | grep -c "handle event_probe" 2>/dev/null || echo 0)"
    drag_begin_count="$(printf "%s\n" "$SLICE" | grep -c "handle drag_begin" 2>/dev/null || echo 0)"
    drag_update_count="$(printf "%s\n" "$SLICE" | grep -c "handle drag_update" 2>/dev/null || echo 0)"
    drag_end_count="$(printf "%s\n" "$SLICE" | grep -c "handle drag_end" 2>/dev/null || echo 0)"
    open_outcome_count="$(printf "%s\n" "$SLICE" | grep -c "outcome=OpenOverlay" 2>/dev/null || echo 0)"
    overlay_open_count="$(printf "%s\n" "$SLICE" | grep -c "overlay open from=" 2>/dev/null || echo 0)"

    info "event counts" "event_probe=$probe_count drag_begin=$drag_begin_count drag_update=$drag_update_count drag_end=$drag_end_count outcome=OpenOverlay=$open_outcome_count overlay_open=$overlay_open_count"

    # Largest |accumulated_dy| reported at any drag_end. The format is
    # `accumulated_dy=-12.3` (negative for upward); we strip the sign and
    # the fractional part, then take the max integer.
    max_abs_dy="$(printf "%s\n" "$SLICE" | sed -n "s/.*accumulated_dy=-\{0,1\}\([0-9][0-9]*\)\.[0-9]*.*/\1/p" | sort -n | tail -n 1)"
    if [ -n "$max_abs_dy" ]; then
        info "max |accumulated_dy| seen" "${max_abs_dy}px (open threshold = 48px)"
    fi

    if [ "$map_line" = "" ]; then
        info "swipe pipeline" "no handle_window map yet; nothing to analyze"
    elif [ "$probe_count" -eq 0 ] && [ "$drag_begin_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "handle_window mapped but ZERO input events reached the strip — Phoc/Phosh is consuming the touch before it can be delivered to the overlay layer-shell surface; verify ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 is in /proc/$PHOSH_PID/environ and that Phoc honors zwlr_layer_shell_v1 Overlay layer ordering"
    elif [ "$probe_count" -gt 0 ] && [ "$drag_begin_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "raw events reach the strip ($probe_count event_probe lines) but GestureDrag.drag_begin never fires — the gesture controller is misconfigured (button mask, propagation phase, or strip hit-region)"
    elif [ "$drag_begin_count" -gt 0 ] && [ "$drag_update_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "drag_begin fires but drag_update never does — the sequence is being denied/cancelled before any motion event flows; check that nothing else is claiming the wl_touch sequence"
    elif [ "$drag_update_count" -gt 0 ] && [ "$open_outcome_count" -eq 0 ]; then
        if [ -n "$max_abs_dy" ] && [ "$max_abs_dy" -lt 48 ]; then
            warn "swipe pipeline" \
                "drag motion is flowing but no swipe ever reached the 48px open threshold (max |dy|=${max_abs_dy}px) — sequence likely cancelled when the pointer leaves the 24px strip; verify GestureDrag set_exclusive(true) + set_state(Claimed) are taking effect"
        else
            warn "swipe pipeline" \
                "drag motion received but evaluate_swipe_up never returned OpenOverlay — check open_threshold_px"
        fi
    elif [ "$open_outcome_count" -gt 0 ] && [ "$overlay_open_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "OpenOverlay outcome reached but the state machine rejected the open() transition — check OverlayState::try_transition"
    elif [ "$overlay_open_count" -gt 0 ]; then
        pass "swipe pipeline" "drag → threshold → open() observed end-to-end"
    else
        info "swipe pipeline" "no swipe events recorded yet; perform a slow upward drag from the bottom strip and re-run"
    fi
fi

# ----- Layer-shell / foreign-toplevel globals advertised by phoc -----
header "Compositor globals (wayland-info)"
if command -v wayland-info >/dev/null 2>&1; then
    if [ -n "$PHOSH_PID" ]; then
        wl_runtime="$(tr "\000" "\n" < "/proc/$PHOSH_PID/environ" | awk -F= "/^XDG_RUNTIME_DIR=/ {print \$2; exit}")"
        wl_display="$(tr "\000" "\n" < "/proc/$PHOSH_PID/environ" | awk -F= "/^WAYLAND_DISPLAY=/ {print \$2; exit}")"
        if [ -n "$wl_runtime" ] && [ -n "$wl_display" ]; then
            globals="$(XDG_RUNTIME_DIR="$wl_runtime" WAYLAND_DISPLAY="$wl_display" wayland-info 2>/dev/null | grep -E "interface: .(zwlr_layer_shell_v1|zphoc_layer_shell_effects_v1|zwlr_foreign_toplevel_manager_v1)" || true)"
            if [ -n "$globals" ]; then
                info "wayland globals" "$(echo "$globals" | tr "\n" "|")"
                if echo "$globals" | grep -q zwlr_layer_shell_v1; then pass "compositor advertises zwlr_layer_shell_v1"; else warn "compositor advertises zwlr_layer_shell_v1" "missing"; fi
                if echo "$globals" | grep -q zwlr_foreign_toplevel_manager_v1; then pass "compositor advertises zwlr_foreign_toplevel_manager_v1"; else warn "compositor advertises zwlr_foreign_toplevel_manager_v1" "missing — card list will be empty"; fi
            else
                info "wayland-info" "ran ok but no matching globals captured; check phoc build"
            fi
        else
            info "wayland-info" "no WAYLAND_DISPLAY/XDG_RUNTIME_DIR in phosh env"
        fi
    fi
else
    info "wayland-info" "not installed; skipping (apk add wayland-utils to enable)"
fi

# ----- gnome-session lifecycle resolution -----
header "gnome-session lifecycle resolution"
if command -v journalctl >/dev/null 2>&1; then
    info "journalctl --user gnome-session --no-pager -n 80" "(may be empty if user units unavailable)"
    journalctl --user -u gnome-session --no-pager -n 80 2>/dev/null | grep -iE "atomos-app-handler|show|hide" || true
fi
'

POST_UNLOCK_RUNTIME_CHECKS="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"

REMOTE_SCRIPT="${REMOTE_SCRIPT}
${POST_UNLOCK_RUNTIME_CHECKS}
TS_BEGIN=\"\$(date -Iseconds 2>/dev/null || date)\"
atomos_post_unlock_capture_baseline
atomos_post_unlock_check_phosh_profile_env_readable
atomos_post_unlock_check_phoc_process_stable
atomos_post_unlock_check_phoc_journal_since \"\$TS_BEGIN\"

echo
header \"Post-unlock smoke hint\"
info \"full unlock smoke\" \"run on host: bash scripts/app-handler/smoke-post-unlock.sh <profile> <ssh-target>\"

if [ \"\$fail\" -eq 0 ]; then
    echo \"RESULT: all checks PASS — if swipe still does nothing, attach ATOMOS_APP_HANDLER_DEBUG_TINT=1 and re-test, then re-run diagnose.\"
    exit 0
else
    echo \"RESULT: at least one check FAILED — fix the FAIL lines top-to-bottom (top is closest to the root cause).\"
    exit 1
fi
"

echo "Running diagnostics on $SSH_TARGET (port $SSH_PORT)..."
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
