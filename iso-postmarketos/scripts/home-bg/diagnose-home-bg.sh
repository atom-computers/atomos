#!/bin/bash
# Diagnose the atomos-home-bg wallpaper-webview pipeline on a running device.
#
# Walks every link in the chain — files installed, assets present, env wired,
# process up, WebKit WebGL support, console logs, and JS diagnostics — and
# prints one PASS/FAIL/INFO line per check.
#
# Usage:
#   bash scripts/home-bg/diagnose-home-bg.sh <profile-env> <ssh-target>
#
# Environment knobs:
#   ATOMOS_DEVICE_SSH_PORT (default 2222; set to 22 for standard hardware)
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

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-22}"
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
#
# Keep this script POSIX-shell friendly — Alpine's busybox /bin/sh
# does not have bash-isms, and ZERO single quotes can be used inside
# REMOTE_SCRIPT since the entire block is single-quoted at the local level.
REMOTE_SCRIPT='
set -u
fail=0
pass() { echo "PASS  $1${2:+ -- $2}"; }
warn() { echo "FAIL  $1 -- $2"; fail=1; }
info() { echo "INFO  $1 -- $2"; }
header() { echo; echo "=== $1 ==="; }

count_matches() {
    _n=$(printf "%s\n" "$1" | grep -c "$2" 2>/dev/null || true)
    _n=${_n:-0}
    printf "%s" "$_n" | head -n 1
}

# ----- Files installed -----
header "Files installed by install-atomos-home-bg.sh"
for p in /usr/local/bin/atomos-home-bg /usr/bin/atomos-home-bg /usr/libexec/atomos-home-bg; do
    if [ -x "$p" ]; then pass "executable $p"; else warn "executable $p" "missing or not +x"; fi
done

for f in \
    /usr/share/atomos-home-bg/black-hole/index.html \
    /usr/share/atomos-home-bg/black-hole/event-horizon.js \
    /usr/share/atomos-home-bg/light-earth/index.html \
    /usr/share/atomos-home-bg/light-earth/index.js; do
    if [ -f "$f" ]; then pass "asset file $f present"; else warn "asset file $f" "missing"; fi
done

if [ -f /etc/xdg/autostart/atomos-home-bg.desktop ]; then
    pass "/etc/xdg/autostart/atomos-home-bg.desktop present"
    if grep -q "^Exec=/usr/libexec/atomos-home-bg --show$" /etc/xdg/autostart/atomos-home-bg.desktop; then
        pass "autostart Exec= contract"
    else
        warn "autostart Exec= contract" "expected: Exec=/usr/libexec/atomos-home-bg --show"
    fi
else
    warn "/etc/xdg/autostart/atomos-home-bg.desktop" "missing; home-bg will not autostart on session start"
fi

# ----- Runtime library dependencies (ldd) -----
header "Runtime library deps (ldd)"
if command -v ldd >/dev/null 2>&1 && [ -x /usr/local/bin/atomos-home-bg ]; then
    missing="$(ldd /usr/local/bin/atomos-home-bg 2>&1 | grep -i "not found" || true)"
    if [ -z "$missing" ]; then
        pass "ldd /usr/local/bin/atomos-home-bg" "no missing libraries"
    else
        warn "ldd /usr/local/bin/atomos-home-bg" "missing: $missing"
    fi
else
    info "ldd" "ldd unavailable or binary missing; skipping"
fi

for lib in libgtk-4 libgtk4-layer-shell libwebkitgtk-6.0 libadwaita; do
    found="$(find /usr/lib /usr/local/lib /lib -maxdepth 4 -name "${lib}*" 2>/dev/null | head -n 1 || true)"
    if [ -n "$found" ]; then
        pass "library present" "$lib -> $found"
    else
        warn "library present" "$lib missing in /usr/lib /usr/local/lib /lib (atomos-home-bg needs webkit2gtk-6.0 and gtk4-layer-shell)"
    fi
done

# ----- Process state -----
header "Process / runtime state"
HOME_BG_BIN_PIDS="$(pgrep -f "/usr/local/bin/atomos-home-bg" 2>/dev/null || true)"
HOME_BG_LAUNCHER_PIDS="$(pgrep -f "/usr/libexec/atomos-home-bg" 2>/dev/null || true)"
PHOSH_PID=""
pid="$(pgrep -x phosh 2>/dev/null | head -n1 || true)"
[ -n "$pid" ] && PHOSH_PID="$pid"
[ -z "$PHOSH_PID" ] && pid="$(pgrep -x phosh.real 2>/dev/null | head -n1 || true)" && PHOSH_PID="$pid"

if [ -n "$HOME_BG_BIN_PIDS" ]; then
    pass "atomos-home-bg binary running" "pid(s): $HOME_BG_BIN_PIDS"
else
    warn "atomos-home-bg binary running" "no active process; wallpaper webview is missing from home background"
fi

if [ -n "$HOME_BG_LAUNCHER_PIDS" ]; then
    info "atomos-home-bg launcher processes" "pid(s): $HOME_BG_LAUNCHER_PIDS"
fi

if [ -n "$PHOSH_PID" ]; then
    pass "phosh running" "pid $PHOSH_PID"
else
    warn "phosh running" "no phosh process detected"
fi

# ----- Runtime Paths and Markers -----
header "Runtime Paths and Markers"
RUNTIME_DIR=""
for d in /run/user/*; do
    [ -d "$d" ] || continue
    RUNTIME_DIR="$d"
    break
done

if [ -n "$RUNTIME_DIR" ]; then
    pidfile="$RUNTIME_DIR/atomos-home-bg.pid"
    if [ -f "$pidfile" ]; then
        stale_pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            cmdline_dump="$(tr "\000" " " < "/proc/$stale_pid/cmdline" 2>/dev/null || true)"
            if echo "$cmdline_dump" | grep -q "atomos-home-bg"; then
                pass "atomos-home-bg pidfile matches running pid" "$pidfile -> $stale_pid"
            else
                warn "atomos-home-bg pidfile points to unrelated process" "$pidfile -> $stale_pid (cmdline: [$cmdline_dump])"
            fi
        else
            warn "atomos-home-bg pidfile is stale" "$pidfile -> $stale_pid (process is gone)"
        fi
    else
        info "atomos-home-bg pidfile" "not present"
    fi

    layerfile="$RUNTIME_DIR/atomos-home-bg.layer"
    if [ -f "$layerfile" ]; then
        layer_val="$(cat "$layerfile" 2>/dev/null || true)"
        pass "atomos-home-bg active layer" "$layer_val (from $layerfile)"
    else
        info "atomos-home-bg active layer" "unknown (no $layerfile file)"
    fi

    disable_file="$RUNTIME_DIR/atomos-home-bg.disabled"
    if [ -f "$disable_file" ]; then
        warn "atomos-home-bg disable marker present" "$disable_file -- launcher will skip startup (usually written when exit code is 127). Fix: rm $disable_file"
    else
        pass "no disable marker present"
    fi
else
    warn "runtime user directory" "no directory found under /run/user/*; process paths may be using fallbacks"
fi

# ----- Env var visibility -----
header "Env var visibility (proc/<pid>/environ)"
ACTIVE_BIN_PID="$(echo "$HOME_BG_BIN_PIDS" | head -n 1)"
if [ -n "$ACTIVE_BIN_PID" ] && [ -r "/proc/$ACTIVE_BIN_PID/environ" ]; then
    env_dump="$(tr "\000" "\n" < "/proc/$ACTIVE_BIN_PID/environ" | grep -E "^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|GDK_BACKEND|GSK_RENDERER|LIBGL_ALWAYS_SOFTWARE|ATOMOS_HOME_BG_)" | tr "\n" " ")"
    info "active process env" "${env_dump:-<no relevant vars>}"
    
    if echo "$env_dump" | grep -q "ATOMOS_HOME_BG_ENABLE_RUNTIME=1"; then
        pass "process env ATOMOS_HOME_BG_ENABLE_RUNTIME=1"
    else
        warn "process env ATOMOS_HOME_BG_ENABLE_RUNTIME=1" "runtime disabled; surface will not be presented"
    fi

    if echo "$env_dump" | grep -q "WAYLAND_DISPLAY="; then
        pass "process env WAYLAND_DISPLAY present"
    else
        warn "process env WAYLAND_DISPLAY present" "missing WAYLAND_DISPLAY; cannot connect to Wayland compositor"
    fi
else
    info "process env" "process not running or environ not readable"
fi

# ----- Log inspection & Webview Diagnostics -----
header "Log inspection & Webview Diagnostics"
LOG_FOUND=0
for log in /run/user/*/atomos-home-bg.log; do
    if [ -f "$log" ]; then
        LOG_FOUND=1
        info "home-bg log path" "$log"
        echo "----8<---- Last 60 lines of $log ----8<----"
        tail -n 60 "$log" || true
        echo "----8<---- End of log ----8<----"

        SLICE="$(tail -n 150 "$log" 2>/dev/null || cat "$log")"

        # Check for WebGL support, webkit settings
        if printf "%s\n" "$SLICE" | grep -q "webgl=true"; then
            pass "WebKit WebGL enabled in settings"
        elif printf "%s\n" "$SLICE" | grep -q "webgl=false"; then
            warn "WebKit WebGL disabled in settings" "check apply_webview_settings or webkit parameters"
        fi

        if printf "%s\n" "$SLICE" | grep -q "hw-accel=Always"; then
            pass "WebKit hardware acceleration policy: Always"
        elif printf "%s\n" "$SLICE" | grep -q "hw-accel="; then
            info "WebKit hardware acceleration policy" "$(printf "%s\n" "$SLICE" | grep "hw-accel=" | tail -n 1)"
        fi

        # Check for WebGL / Context errors
        if printf "%s\n" "$SLICE" | grep -iq "WebGL unavailable" || printf "%s\n" "$SLICE" | grep -iq "getContext('webgl') returned null"; then
            warn "WebGL context creation failed" "the WebKit WebGL context could not be instantiated; WebGL accretion disk will be blank. Ensure GPU drivers are loaded or check LIBGL_ALWAYS_SOFTWARE."
        elif printf "%s\n" "$SLICE" | grep -iq "WebGL context lost"; then
            warn "WebGL context lost event captured" "browser reports WebGL context was lost"
        fi

        # Check for shader compiling and program linking errors
        if printf "%s\n" "$SLICE" | grep -iq "shader compile error" || printf "%s\n" "$SLICE" | grep -iq "shader compile failed"; then
            warn "WebGL Shader compilation failed" "check fragment/vertex source logs above"
        fi
        if printf "%s\n" "$SLICE" | grep -iq "program link error" || printf "%s\n" "$SLICE" | grep -iq "program link failed"; then
            warn "WebGL Program link failed" "check link log"
        fi

        # Check for Javascript console errors / exceptions
        js_errors="$(printf "%s\n" "$SLICE" | grep -E "event-horizon:.*(Exception|Error|failed|missing|unavailable|threw)" || true)"
        if [ -n "$js_errors" ]; then
            warn "Javascript errors or warnings detected in WebView" "matches:\n$js_errors"
        else
            if printf "%s\n" "$SLICE" | grep -q "event-horizon: ready" || printf "%s\n" "$SLICE" | grep -q "event-horizon: rendering"; then
                pass "Javascript accretion-disk running cleanly" "logs confirm active rendering"
            else
                info "Javascript accretion-disk state" "no explicit error or ready log found in the slice"
            fi
        fi

        # Check launcher lifecycle markers
        if printf "%s\n" "$SLICE" | grep -q "action=show"; then
            pass "Launcher received show event"
        fi
        if printf "%s\n" "$SLICE" | grep -q "action=hide"; then
            pass "Launcher received hide event"
        fi
        if printf "%s\n" "$SLICE" | grep -q "exited immediately"; then
            warn "Process exited immediately" "check log for Wayland socket connection errors or crash logs"
        fi
        if printf "%s\n" "$SLICE" | grep -q "process-exit rc="; then
            exit_code="$(printf "%s\n" "$SLICE" | grep "process-exit rc=" | tail -n 1)"
            warn "Process exited with non-zero exit code" "$exit_code"
        fi
    fi
done

if [ "$LOG_FOUND" = "0" ]; then
    warn "atomos-home-bg log" "no log found at /run/user/*/atomos-home-bg.log -- launcher has never run or log has not been redirected"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: all home-bg checks PASS — the wallpaper webview should be rendering."
    exit 0
else
    echo "RESULT: at least one home-bg check FAILED — check the FAIL lines above and hotfix home-bg."
    exit 1
fi
'

# Host-side guard: the remote blob is assigned inside a single-quoted literal;
# any ASCII single quote inside it truncates the assignment and breaks SSH.
case $REMOTE_SCRIPT in *"'"*)
    echo "diagnose-home-bg.sh: REMOTE_SCRIPT contains a single quote; fix quoting before shipping" >&2
    exit 1
    ;;
esac

echo "Running home-bg diagnostics on $SSH_TARGET (port $SSH_PORT)..."
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
