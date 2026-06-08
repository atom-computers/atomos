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

# busybox grep -c prints 0 and exits 1 when there are no matches; pairing it
# with `|| echo 0` yields "0\n0" and breaks `[ "$n" -eq 0 ]` downstream.
count_matches() {
    _n=$(printf "%s\n" "$1" | grep -c "$2" 2>/dev/null || true)
    _n=${_n:-0}
    printf "%s" "$_n" | head -n 1
}

# ----- Files installed -----
header "Files installed by install-app-handler.sh"
for p in /usr/local/bin/atomos-app-handler /usr/bin/atomos-app-handler /usr/libexec/atomos-app-handler; do
    if [ -x "$p" ]; then pass "executable $p"; else warn "executable $p" "missing or not +x"; fi
done
if [ -f /etc/atomos/app-handler-contract ]; then
    pass "/etc/atomos/app-handler-contract present"
    if grep -q "^app-handler-v1-launch-switcher-dbus-home$" /etc/atomos/app-handler-contract; then
        pass "app-handler lifecycle contract marker"
    else
        warn "app-handler lifecycle contract marker" "expected app-handler-v1-launch-switcher-dbus-home"
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
APP_HANDLER_PIDS="$(pgrep -f "/usr/local/bin/atomos-app-handler" 2>/dev/null || true)"
PHOSH_PID="$(find_phosh_pid)"
if [ -n "$APP_HANDLER_PIDS" ]; then
    pass "atomos-app-handler running (handle bar)" "pid(s): $APP_HANDLER_PIDS"
else
    warn "atomos-app-handler running (handle bar)" "no process; the visible swipe-up bar will be missing"
fi
if [ -n "$PHOSH_PID" ]; then
    pass "phosh running" "pid $PHOSH_PID"
else
    info "phosh running" "no phosh process"
fi

# ----- Chat-UI runtime state (cross-component) -----
# When the user reports chat-ui not loading on the home screen on the
# 2nd run after `make qemu` quit + relaunch, the failure mode is almost
# always persistent state that survived the QEMU disk image (mounted
# without `snapshot=on` in scripts/qemu/run-local-qemu.sh:141). This
# section captures the four gates the launcher script
# /usr/libexec/atomos-overview-chat-ui checks before spawning the
# binary, so we can see at a glance which one is stuck.
#
# REMOTE_SCRIPT is single-quoted on the host side, so this whole block
# must contain ZERO ASCII single quotes. awk programs use double-quoted
# bodies (with \$ escapes); English messages avoid contractions.
header "Chat-UI runtime state (post-unlock divergence checks)"
CHAT_UI_BIN="/usr/local/bin/atomos-overview-chat-ui"
CHAT_UI_LAUNCHER="/usr/libexec/atomos-overview-chat-ui"
CHAT_UI_AUTOSTART="/etc/xdg/autostart/atomos-overview-chat-ui.desktop"

if [ -x "$CHAT_UI_BIN" ]; then
    pass "chat-ui binary executable" "$CHAT_UI_BIN"
else
    warn "chat-ui binary executable" "$CHAT_UI_BIN missing or not +x"
fi
if [ -x "$CHAT_UI_LAUNCHER" ]; then
    pass "chat-ui launcher script" "$CHAT_UI_LAUNCHER"
else
    warn "chat-ui launcher script" "$CHAT_UI_LAUNCHER missing"
fi
if [ -f "$CHAT_UI_AUTOSTART" ]; then
    pass "chat-ui autostart .desktop" "$CHAT_UI_AUTOSTART"
else
    warn "chat-ui autostart .desktop" "$CHAT_UI_AUTOSTART missing -- Phosh will not fire --show on session start"
fi

CHAT_UI_BG_PIDS="$(pgrep -f "$CHAT_UI_BIN" 2>/dev/null || true)"
CHAT_UI_LAUNCHER_PIDS="$(pgrep -f "$CHAT_UI_LAUNCHER" 2>/dev/null || true)"
if [ -n "$CHAT_UI_BG_PIDS" ]; then
    pass "chat-ui binary running" "pid(s): $CHAT_UI_BG_PIDS"
else
    warn "chat-ui binary running" "no /usr/local/bin/atomos-overview-chat-ui process -- the home screen will be blank/wallpaper-only"
fi
if [ -n "$CHAT_UI_LAUNCHER_PIDS" ]; then
    info "chat-ui launcher script processes" "pid(s): $CHAT_UI_LAUNCHER_PIDS (lingering --show wrappers; mostly harmless)"
fi

# Per-user runtime dir contents -- pidfile + disable marker live here.
# Also report whether the dir is tmpfs (expected: gone on every reboot,
# so a stale pidfile/disable marker is a symptom of a non-tmpfs /run).
CHAT_UI_RUNTIME_DIR=""
for d in /run/user/*; do
    [ -d "$d" ] || continue
    CHAT_UI_RUNTIME_DIR="$d"
    break
done
if [ -n "$CHAT_UI_RUNTIME_DIR" ]; then
    mount_type="$(awk -v t="$CHAT_UI_RUNTIME_DIR" "\$2 == t {print \$3; exit}" /proc/mounts 2>/dev/null || true)"
    if [ -z "$mount_type" ]; then
        mount_type="$(awk "\$2 == \"/run/user\" {print \$3; exit}" /proc/mounts 2>/dev/null || true)"
        [ -z "$mount_type" ] && mount_type="$(awk "\$2 == \"/run\" {print \$3; exit}" /proc/mounts 2>/dev/null || true)"
    fi
    if [ "$mount_type" = "tmpfs" ]; then
        pass "$CHAT_UI_RUNTIME_DIR is tmpfs" "(stale pidfile/disable-marker should be impossible across reboots)"
    elif [ -n "$mount_type" ]; then
        warn "$CHAT_UI_RUNTIME_DIR mount type" "$mount_type -- NOT tmpfs; pidfile/disable marker can persist across QEMU reboots and silently break chat-ui startup on 2nd run"
    else
        info "$CHAT_UI_RUNTIME_DIR mount type" "could not resolve from /proc/mounts (Alpine busybox mount line format)"
    fi

    pidfile="$CHAT_UI_RUNTIME_DIR/atomos-overview-chat-ui.pid"
    if [ -f "$pidfile" ]; then
        stale_pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            cmdline_dump="$(tr "\000" " " < "/proc/$stale_pid/cmdline" 2>/dev/null || true)"
            case "$cmdline_dump" in
                */usr/local/bin/atomos-overview-chat-ui*)
                    info "chat-ui pidfile" "$pidfile -> $stale_pid (GTK binary)"
                    ;;
                */usr/libexec/atomos-overview-chat-ui*)
                    warn "chat-ui pidfile points at launcher shell" \
                        "$pidfile -> $stale_pid cmdline=[$cmdline_dump]. Phosh layer --show kills the shell but leaves the GTK binary on the wrong layer (home looks empty). Reinstall launcher from install-overview-chat-ui.sh (exec pidfile fix) or: kill stray binary, rm pidfile, run: ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay /usr/libexec/atomos-overview-chat-ui --show"
                    ;;
                *)
                    warn "chat-ui pidfile points to PID-reuse" \
                        "$pidfile -> $stale_pid cmdline=[$cmdline_dump] (NOT chat-ui). Fix: rm $pidfile; ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay /usr/libexec/atomos-overview-chat-ui --show"
                    ;;
            esac
        else
            warn "chat-ui pidfile is stale" \
                "$pidfile -> $stale_pid but kill -0 fails (process gone). Harmless on its own, but indicates /run/user/ persists across reboots"
        fi
    else
        info "chat-ui pidfile" "$pidfile not present (first run, or chat-ui exited cleanly)"
    fi

    chat_ui_layer_env=""
    chat_ui_binary_pid="$(echo "$CHAT_UI_BG_PIDS" | awk "{print \$1}")"
    if [ -n "$chat_ui_binary_pid" ] && [ -r "/proc/$chat_ui_binary_pid/environ" ]; then
        chat_ui_layer_env="$(tr "\000" "\n" < "/proc/$chat_ui_binary_pid/environ" 2>/dev/null | grep "^ATOMOS_OVERVIEW_CHAT_UI_LAYER=" | head -n1 || true)"
    fi
    if [ -n "$chat_ui_layer_env" ]; then
        info "chat-ui process layer env" "$chat_ui_layer_env"
        if echo "$chat_ui_layer_env" | grep -q "=bottom$"; then
            warn "chat-ui on layer=bottom (invisible on unfolded home)" \
                "Unlock is not enough: swipe UP on the Phosh home bar until the overview is fully open. Phosh must log action=show layer=overlay in atomos-overview-chat-ui.log. Manual: ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay /usr/libexec/atomos-overview-chat-ui --show"
        elif echo "$chat_ui_layer_env" | grep -q "=top$"; then
            warn "chat-ui on layer=top while home should be visible" \
                "phosh-home is a TOP layer-shell surface too, so chat-ui paints underneath it and looks invisible. Rebuild phosh with overlay-on-unfold fix or run: ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay /usr/libexec/atomos-overview-chat-ui --show"
        elif echo "$chat_ui_layer_env" | grep -q "=overlay$"; then
            pass "chat-ui layer env is overlay (above phosh-home)" "$chat_ui_layer_env (must be hidden while locked; rebuild phosh if visible on lock screen)"
        else
            pass "chat-ui layer env is not bottom/top" "$chat_ui_layer_env"
        fi
    else
        info "chat-ui process layer env" "ATOMOS_OVERVIEW_CHAT_UI_LAYER unset in binary environ (defaults to overlay in overlay.rs)"
    fi

    HOME_BG_PIDS="$(pgrep -f "/usr/local/bin/atomos-home-bg" 2>/dev/null || true)"
    if [ -n "$HOME_BG_PIDS" ]; then
        pass "atomos-home-bg running" "pid(s): $HOME_BG_PIDS"
    else
        warn "atomos-home-bg running" "no process -- chat-ui is transparent but wallpaper/webview may be missing"
    fi

    disable_file="$CHAT_UI_RUNTIME_DIR/atomos-overview-chat-ui.disabled"
    if [ -f "$disable_file" ]; then
        warn "chat-ui disable marker present" \
            "$disable_file -- launcher will skip starting the binary. Usually written when the binary exited rc=127 (missing shared lib). Delete it to re-enable: rm $disable_file"
    else
        pass "chat-ui no disable marker"
    fi
fi

# Tail the chat-ui launcher log so we see startup attempts and exits.
header "Chat-UI launcher log (last 60 lines)"
chat_ui_log_found=0
for log in /run/user/*/atomos-overview-chat-ui.log; do
    if [ -f "$log" ]; then
        chat_ui_log_found=1
        info "chat-ui log path" "$log"
        echo "----8<----"
        tail -n 60 "$log" || true
        echo "----8<----"
    fi
done
if [ "$chat_ui_log_found" = "0" ]; then
    warn "chat-ui launcher log" "no /run/user/*/atomos-overview-chat-ui.log present -- the launcher script never ran (autostart did not fire) or /run/user/ is on a different mount than the launcher writes to"
fi

# Pinpoint exited-immediately / Wayland-bind / CSS-parse-error issues so
# the user gets a one-line classification.
chat_ui_classified=0
for log in /run/user/*/atomos-overview-chat-ui.log; do
    [ -f "$log" ] || continue
    if grep -q "exited immediately" "$log"; then
        warn "chat-ui startup classification" \
            "log contains [exited immediately] -- binary failed to bind Wayland (compositor not ready, or WAYLAND_DISPLAY/XDG_RUNTIME_DIR mismatch)"
        chat_ui_classified=1
    fi
    if grep -q "Theme parser error" "$log"; then
        warn "chat-ui startup classification" \
            "log contains [Theme parser error] -- CSS provider declarations rejected (e.g. !important after a value), layer-shell paints opaque over atomos-home-bg"
        chat_ui_classified=1
    fi
    if grep -q "main phase=after-run" "$log"; then
        info "chat-ui startup classification" "log contains [main phase=after-run] -- binary returned from app.run() (clean exit; UI gone)"
        chat_ui_classified=1
    fi
    if grep -q "ATOMOS_OVERVIEW_CHAT_UI_LAYER=bottom" "$log"; then
        warn "chat-ui startup classification" \
            "log shows layer=bottom -- expected until home unfolds; Phosh must run overlay --show (see chat-ui lifecycle log below)"
        chat_ui_classified=1
    fi
    if grep -q "layer=overlay" "$log" || grep -q "ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay" "$log"; then
        pass "chat-ui startup classification" "log shows layer=overlay (above phosh-home)"
        chat_ui_classified=1
    fi
done

# Phosh binary must ship the overlay-on-unfold lifecycle (strings survive musl strip).
phosh_bin=""
for candidate in /usr/libexec/phosh /usr/bin/phosh; do
    if [ -x "$candidate" ]; then
        phosh_bin="$candidate"
        break
    fi
done
if [ -n "$phosh_bin" ] && command -v strings >/dev/null 2>&1; then
    if strings "$phosh_bin" 2>/dev/null | grep -q "atomos-overview-chat-ui"; then
        pass "phosh binary references overview-chat-ui launcher"
    else
        warn "phosh binary references overview-chat-ui launcher" \
            "strings $phosh_bin missing atomos-overview-chat-ui — stock phosh will never drive overlay --show; rebuild with make build-qemu"
    fi
    if strings "$phosh_bin" 2>/dev/null | grep -q "ATOMOS_OVERVIEW_CHAT_UI_LAYER=top"; then
        warn "phosh binary still embeds LAYER=top" \
            "rebuild phosh (home.c must use overlay on unfold, not top)"
    elif strings "$phosh_bin" 2>/dev/null | grep -q "overlay"; then
        pass "phosh binary embeds overlay layer string"
    else
        info "phosh overlay layer string" "could not confirm overlay in strings output (binary may be stripped)"
    fi
else
    info "phosh binary strings check" "skipped (no phosh binary or strings(1) missing)"
fi

chat_ui_saw_overlay_show=0
for log in /run/user/*/atomos-overview-chat-ui.log; do
    [ -f "$log" ] || continue
    if grep -q "action=show.*layer=overlay" "$log" 2>/dev/null; then
        chat_ui_saw_overlay_show=1
    fi
done
if [ "$chat_ui_saw_overlay_show" = "1" ]; then
    pass "chat-ui lifecycle log" "Phosh overlay --show recorded in atomos-overview-chat-ui.log"
elif [ "$chat_ui_log_found" = "1" ]; then
    info "chat-ui lifecycle log" \
        "no action=show layer=overlay in log yet — unfold home after unlock, or phosh is stale; autostart should use --start not --show"
fi
for log in /run/user/*/atomos-overview-chat-ui.log; do
    [ -f "$log" ] || continue
    if grep -q "action=hide" "$log" 2>/dev/null && ! grep -q "action=show" "$log" 2>/dev/null; then
        warn "chat-ui hide without show" \
            "log has action=hide but no action=show — Phosh killed autostart chat-ui (map-idle while locked or stale phosh); rebuild phosh home.c fix"
        break
    fi
done
if [ "$chat_ui_classified" = "0" ] && [ "$chat_ui_log_found" = "1" ]; then
    info "chat-ui startup classification" "no known failure marker in log; binary is either running or the failure is novel"
fi

# Snapshot of chat-ui-relevant per-user state that COULD persist across
# qemu reboots and silently break the 2nd run.
header "Chat-UI persistent state (survives QEMU reboot when disk has no snapshot=on)"
USER_HOME="$(awk -F: "\$3 == 10000 {print \$6; exit}" /etc/passwd 2>/dev/null || true)"
if [ -z "$USER_HOME" ]; then
    USER_HOME="/home/user"
fi
info "user home (uid 10000)" "$USER_HOME"
for f in \
    "$USER_HOME/.config/autostart" \
    "$USER_HOME/.config/dconf/user" \
    "$USER_HOME/.cache/sessions" \
    "$USER_HOME/.local/state/atomos-overview-chat-ui" ; do
    if [ -e "$f" ]; then
        sz="$(du -sh "$f" 2>/dev/null | awk "{print \$1}" || echo "?")"
        info "persistent state present" "$f (size=$sz)"
    fi
done
if [ -d /etc/atomos ]; then
    info "/etc/atomos contents" "$(ls -la /etc/atomos 2>/dev/null | awk "NR>1 {print \$9}" | tr "\n" " ")"
fi

# ----- Env var visibility -----
header "Env var visibility (proc/<pid>/environ)"
if [ -n "$APP_HANDLER_PIDS" ]; then
    AS_PID="$(echo "$APP_HANDLER_PIDS" | head -n 1)"
    if [ -r "/proc/$AS_PID/environ" ]; then
        env_dump="$(tr "\000" "\n" < "/proc/$AS_PID/environ" | grep -E "^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|GDK_BACKEND|ATOMOS_APP_HANDLER_)" | tr "\n" " ")"
        info "app-handler env" "${env_dump:-<no relevant vars>}"
        if echo "$env_dump" | grep -q "ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1"; then
            pass "app-handler sees ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1"
        else
            warn "app-handler sees ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1" "binary will exit early without presenting a surface"
        fi
        if echo "$env_dump" | grep -q "WAYLAND_DISPLAY="; then
            pass "app-handler sees WAYLAND_DISPLAY"
        else
            warn "app-handler sees WAYLAND_DISPLAY" "binary cannot connect to the compositor"
        fi
    fi
else
    info "app-handler env" "process not running"
fi

# ----- Phosh runtime env (single most common cause of "bar visible but
# swipe does nothing") -----
#
# The rust handle surface lives on Layer::Overlay so the wlr-layer-shell
# input ordering says touches in the bottom 24 px should reach it BEFORE
# phosh-home (Top). But phoc-layer-shell-effects ships a separate path:
# when phosh-home keeps PhoshDragSurface drag-mode=HANDLE, phoc captures
# touches in the home-bar drag region itself, regardless of higher-layer
# overlays. AtomOS-fork phosh yields the bottom edge iff its process
# sees ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 in /proc/<pid>/environ
# (the atomos_phosh_bottom_edge_drag_disabled() branch in home.c that
# sets drag_mode=NONE).
#
# Reading /etc/atomos/phosh-profile.env from the rootfs is NOT enough --
# phosh-session.in must have actually sourced it before exec-ing phoc,
# and on hotfix/upgrade paths that file might exist but the live phosh
# was started before it landed. So we grep the live phosh environ here
# and remember the result for the swipe-pipeline analysis below.
ATOMOS_PHOSH_EDGE_DRAG_YIELDED=unknown
ATOMOS_PHOSH_TAKES_OVER=unknown
header "Live phosh runtime env (bottom-edge yield to atomos-app-handler)"
if [ -n "$PHOSH_PID" ] && [ -r "/proc/$PHOSH_PID/environ" ]; then
    phosh_env="$(tr "\000" "\n" < "/proc/$PHOSH_PID/environ" \
        | grep -E "^ATOMOS_(PHOSH_DISABLE_BOTTOM_EDGE_DRAG|APP_HANDLER_(TAKES_OVER|ENABLE_RUNTIME))=" \
        | tr "\n" " " || true)"
    info "phosh atomos env" "${phosh_env:-<none of the atomos-app-handler keys in phosh environ>}"
    if echo "$phosh_env" | grep -q "ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1"; then
        pass "phosh sees ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1" \
            "phosh-home will set PhoshDragSurface drag_mode=NONE so phoc yields the bottom edge to the overlay handle"
        ATOMOS_PHOSH_EDGE_DRAG_YIELDED=yes
    else
        warn "phosh sees ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1" \
            "MISSING from phosh environ -- phosh-home stays at drag_mode=HANDLE and phoc swallows every bottom-edge touch BEFORE the wlr-layer-shell Overlay surface gets a chance. This is the single most common cause of \"visible bar, swipe does nothing\". Fix: ensure /etc/atomos/phosh-profile.env contains the key AND phosh-session.in sources it (re-login, or re-run install-app-handler.sh + hotfix-phosh-profile-env.sh, then log out / log back in)."
        ATOMOS_PHOSH_EDGE_DRAG_YIELDED=no
    fi
    if echo "$phosh_env" | grep -q "ATOMOS_APP_HANDLER_TAKES_OVER=1"; then
        pass "phosh sees ATOMOS_APP_HANDLER_TAKES_OVER=1" \
            "PhoshOverview is hidden so the handle bar owns the app surface"
        ATOMOS_PHOSH_TAKES_OVER=yes
    else
        warn "phosh sees ATOMOS_APP_HANDLER_TAKES_OVER=1" \
            "MISSING from phosh environ -- PhoshOverview will paint its own overview on top of the handle bar when unfolded"
        ATOMOS_PHOSH_TAKES_OVER=no
    fi
else
    info "phosh runtime env" "no phosh pid or /proc/<pid>/environ not readable; cannot confirm bottom-edge yield"
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
#   2. handle_canvas resize fired?      → GTK allocated the full-screen canvas
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

    map_line="$(printf "%s\n" "$SLICE" | grep "handle_window map width=" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$map_line" ]; then
        pass "handle_window mapped" "${map_line##*atomos-app-handler: }"
        map_w="$(printf "%s\n" "$map_line" | sed -n "s/.* width=\([0-9][0-9]*\).*/\1/p")"
        map_h="$(printf "%s\n" "$map_line" | sed -n "s/.* height=\([0-9][0-9]*\).*/\1/p")"
        if printf "%s" "$map_line" | grep -q "surface_height_px="; then
            warn "app-handler binary stale" \
                "launcher log still shows surface_height_px= (pre full-screen build). /usr/local/bin may be updated but the running process was not restarted — run: bash scripts/app-handler/hotfix-app-handler.sh <profile> <ssh-target> (must print OK: installed binary contains handle_canvas)"
        elif printf "%s\n" "$SLICE" | grep -q "handle_strip resize"; then
            warn "app-handler binary stale" \
                "launcher log shows handle_strip resize (old 24px surface). Restart atomos-app-handler after hotfix."
        fi
        if [ -n "$map_w" ] && [ "$map_w" -gt 0 ] && [ "$map_w" -lt 360 ]; then
            warn "handle_window width" "${map_w}px < 360 — layer-shell L+R anchors may not be honored; touches outside this strip will miss"
        fi
        # Full-screen overlay: height should be display-sized (typically >= 600).
        # width=0 height=0 is the first map callback before GTK allocates — ignore.
        if [ -n "$map_h" ] && [ "$map_h" -gt 0 ] && [ "$map_h" -lt 200 ]; then
            warn "handle_window height" "${map_h}px < 200 — the handle surface should be full-screen overlay (anchor T as well as L+R+B). Re-run hotfix and confirm the running binary contains handle_canvas."
        fi
    else
        info "handle_window mapped" "no map line in this session — open an app to trigger toplevel_count > 0"
    fi

    resize_line="$(printf "%s\n" "$SLICE" | grep "handle_canvas resize" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$resize_line" ]; then
        pass "handle_canvas allocated" "${resize_line##*atomos-app-handler: }"
    fi

    if strings /usr/local/bin/atomos-app-handler 2>/dev/null | grep -q "handle_canvas resize"; then
        pass "installed binary build" "contains handle_canvas (full-screen fade build)"
    elif [ -x /usr/local/bin/atomos-app-handler ]; then
        warn "installed binary build" \
            "missing handle_canvas string — hotfix did not install the new binary, or the container build was stale"
    fi

    probe_count="$(count_matches "$SLICE" "handle event_probe")"
    drag_begin_count="$(count_matches "$SLICE" "handle drag_begin")"
    drag_update_count="$(count_matches "$SLICE" "handle drag_update")"
    drag_end_count="$(count_matches "$SLICE" "handle drag_end")"
    open_outcome_count="$(count_matches "$SLICE" "outcome=OpenOverlay")"
    overlay_open_count="$(count_matches "$SLICE" "overlay open from=")"
    grab_broken_count="$(count_matches "$SLICE" "event_probe type=GrabBroken")"
    # Peak fade-overlay alpha reported during drag_update lines. Drag start
    # logs `progress=0.000`; at the open threshold it logs `progress=1.000`.
    # A peak < 1.000 means the user never reached the threshold OR the
    # fade is misconfigured.
    max_progress="$(printf "%s\n" "$SLICE" | sed -n "s/.*progress=\([0-9]\.[0-9][0-9][0-9]\).*/\1/p" | sort -n | tail -n 1)"

    info "event counts" "event_probe=$probe_count drag_begin=$drag_begin_count drag_update=$drag_update_count drag_end=$drag_end_count outcome=OpenOverlay=$open_outcome_count overlay_open=$overlay_open_count grab_broken=$grab_broken_count"
    if [ -n "$max_progress" ]; then
        info "max fade progress" "${max_progress} (drag fade ramps 0.000 → 1.000 as |dy| reaches open_threshold_px; the running app fades out in lockstep)"
    fi

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
        if [ "${ATOMOS_PHOSH_EDGE_DRAG_YIELDED:-unknown}" = "no" ]; then
            warn "swipe pipeline" \
                "handle_window mapped but ZERO input events reached the strip AND phosh environ is missing ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 — root cause: phoc is intercepting the bottom-edge touch via phosh-home drag_mode=HANDLE. Fix the phosh env (see the \"Live phosh runtime env\" section above) and re-login, then re-test."
        elif [ "${ATOMOS_PHOSH_EDGE_DRAG_YIELDED:-unknown}" = "yes" ]; then
            warn "swipe pipeline" \
                "handle_window mapped but ZERO input events reached the strip even though phosh environ DOES yield the bottom edge — likely a Phoc layer-ordering bug (Overlay vs Top input routing) or a wlr-layer-shell input-region miss on the handle surface. Capture wayland-info + phoc trace and file upstream."
        else
            warn "swipe pipeline" \
                "handle_window mapped but ZERO input events reached the strip — Phoc/Phosh is consuming the touch before it can be delivered to the overlay layer-shell surface; verify ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 is in /proc/$PHOSH_PID/environ and that Phoc honors zwlr_layer_shell_v1 Overlay layer ordering"
        fi
    elif [ "$probe_count" -gt 0 ] && [ "$drag_begin_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "raw events reach the strip ($probe_count event_probe lines) but GestureDrag.drag_begin never fires — the gesture controller is misconfigured (button mask, propagation phase, or strip hit-region)"
    elif [ "$drag_begin_count" -gt 0 ] && [ "$drag_update_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "drag_begin fires but drag_update never does — the sequence is being denied/cancelled before any motion event flows; check that nothing else is claiming the wl_touch sequence"
    elif [ "$drag_update_count" -gt 0 ] && [ "$open_outcome_count" -eq 0 ]; then
        if [ -n "$max_abs_dy" ] && [ "$max_abs_dy" -lt 48 ] && [ "$grab_broken_count" -gt 0 ]; then
            warn "swipe pipeline" \
                "drag motion flows but the gesture dies at |dy|=${max_abs_dy}px (open threshold = 48px) and the launcher log shows GrabBroken — the wayland pointer grab is being broken even though the handle surface is supposed to be FULL-SCREEN overlay (anchors L+R+T+B). Either (a) the binary on /usr/local/bin/atomos-app-handler is stale and still uses the old 24 px-tall surface — run: bash scripts/app-handler/hotfix-app-handler.sh <profile> <ssh-target>; or (b) phoc is mis-handling the layer-shell pointer grab (capture wayland-info + phoc trace and file upstream)."
        elif [ -n "$max_abs_dy" ] && [ "$max_abs_dy" -lt 48 ]; then
            warn "swipe pipeline" \
                "drag motion is flowing but no swipe ever reached the 48px open threshold (max |dy|=${max_abs_dy}px) and no GrabBroken was logged — the user lifted their finger before completing the gesture (try a longer swipe), OR a competing GTK controller is cancelling the sequence (verify GestureDrag set_exclusive(true) + set_state(Claimed) are taking effect)."
        else
            warn "swipe pipeline" \
                "drag motion received but evaluate_swipe_up never returned OpenOverlay — check open_threshold_px"
        fi
    elif [ "$open_outcome_count" -gt 0 ] && [ "$overlay_open_count" -eq 0 ]; then
        warn "swipe pipeline" \
            "OpenOverlay outcome reached but the state machine rejected the open() transition"
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

# Host-side guard: the remote blob is assigned inside a single-quoted literal;
# any ASCII single quote inside it truncates the assignment and breaks SSH.
case $REMOTE_SCRIPT in *"'"*)
    echo "diagnose-app-handler.sh: REMOTE_SCRIPT contains a single quote; fix quoting before shipping" >&2
    exit 1
    ;;
esac

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
info \"chat-ui overlay runtime\" \"run on host: bash scripts/overview-chat-ui/smoke-chat-ui-post-unlock.sh <profile> <ssh-target>\"

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
