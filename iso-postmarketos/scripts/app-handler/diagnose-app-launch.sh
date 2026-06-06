#!/bin/bash
# Diagnose why tapping an app icon does not open the app on a running device.
#
# This is the launch-path companion to diagnose-app-handler.sh. That script
# covers the swipe-up overlay / handle-bar gesture pipeline; THIS one walks
# the chain that fires when the user taps a tile in the atomos-overview-chat-ui
# app grid:
#
#   tile tap (app_grid.rs:tile_click_launch)
#     -> resolve /usr/libexec/atomos-app-handler   (else direct gio fallback)
#     -> /usr/libexec/atomos-app-handler launch <desktop-id>   (linux.rs:run_launch_once)
#         -> plan_launch(): ActivateExisting (foreign-toplevel) OR SpawnNew
#         -> launch_exec.rs: gio::DesktopAppInfo::new(id).launch()
#             -> spawns the .desktop Exec= / DBus-activates the app
#
# The single most common "some apps do not open" cause is a .desktop entry
# whose Exec= (or TryExec=) binary is not installed on the image, so this
# script resolves every visible entry and prints one PASS/FAIL line per gap.
#
# Mirrors the SSH plumbing in diagnose-app-handler.sh so QEMU users with
#   ssh -p 2222 user@localhost
# can run it unchanged.
#
# Usage:
#   bash scripts/app-handler/diagnose-app-launch.sh <profile-env> <ssh-target>
#
# Environment knobs (same as hotfix/diagnose):
#   ATOMOS_DEVICE_SSH_PORT (default 2222)
#   ATOMOS_DEVICE_SSHPASS / SSHPASS / PMOS_INSTALL_PASSWORD (default 147147)
#   ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID
#       If set (e.g. org.gnome.Calculator), the remote script will actually
#       invoke `/usr/libexec/atomos-app-handler launch <id>` and report the
#       exit status + fresh log lines. Off by default so the diagnostic does
#       not pop windows unless you ask it to.
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
LAUNCH_TEST_APP_ID="${ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID:-}"
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR)

# Remote diagnose script — runs inside /bin/sh on the device. Keep it POSIX
# (Alpine busybox /bin/sh, no bash-isms) and free of ASCII single quotes: the
# whole blob is single-quoted at the host shell level, so any inner single
# quote truncates the assignment. awk bodies use double quotes with \$ escapes;
# English messages avoid contractions.
REMOTE_SCRIPT='
set -u
# A spawned app inherits PATH from the phosh session, which is richer than a
# bare ssh login. Broaden PATH here so Exec= resolution does not false-FAIL on
# binaries that live in standard prefixes the ssh shell did not export.
PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:${PATH:-}"
export PATH

fail=0
pass() { echo "PASS  $1${2:+ -- $2}"; }
warn() { echo "FAIL  $1 -- $2"; fail=1; }
info() { echo "INFO  $1 -- $2"; }
header() { echo; echo "=== $1 ==="; }

LAUNCHER="/usr/libexec/atomos-app-handler"
APP_HANDLER_BIN="/usr/local/bin/atomos-app-handler"
CHAT_UI_BIN="/usr/local/bin/atomos-overview-chat-ui"

# Resolve the uid-10000 (default phosh user) home for per-user .desktop dirs
# and the runtime log dir.
USER_HOME="$(awk -F: "\$3 == 10000 {print \$6; exit}" /etc/passwd 2>/dev/null || true)"
[ -n "$USER_HOME" ] || USER_HOME="/home/user"

# ----- Stage 1: launcher chain installed -----
header "Launch chain installed (chat-ui tile -> app-handler launch -> gio)"
if [ -x "$LAUNCHER" ]; then
    pass "lifecycle launcher present" "$LAUNCHER"
else
    warn "lifecycle launcher present" "$LAUNCHER missing/not +x -- chat-ui tile clicks fall back to a DIRECT gio launch (apps still open, but the home-fold + toplevel de-dup lifecycle is bypassed). If apps do not open at all, the cause is downstream (Exec=)."
fi
if [ -x "$APP_HANDLER_BIN" ]; then
    pass "app-handler binary present" "$APP_HANDLER_BIN"
    if command -v strings >/dev/null 2>&1; then
        blob="$(strings "$APP_HANDLER_BIN" 2>/dev/null || true)"
        if strings "$APP_HANDLER_BIN" 2>/dev/null | grep -q "launch: spawned new app id="; then
            pass "app-handler binary supports launch subcommand" "contains run_launch_once trace string"
        else
            warn "app-handler binary supports launch subcommand" "missing [launch: spawned new app id=] string -- binary predates the launch path; reinstall via install-app-handler.sh"
        fi
        if echo "$blob" | grep -F "syncing session env to dbus activation" >/dev/null 2>&1; then
            pass "app-handler binary includes dbus launch fix" "contains dbus-update-activation-environment sync trace"
        else
            warn "app-handler binary includes dbus launch fix" "missing dbus activation env sync trace -- device still runs a pre-Console-fix binary; run hotfix-app-handler.sh and re-test"
        fi
        if echo "$blob" | grep -F "dbus activatable spawning desktop Exec" >/dev/null 2>&1 \
            || echo "$blob" | grep -F "dbus activatable via launch_uris_as_manager" >/dev/null 2>&1 \
            || echo "$blob" | grep -F "spawning dbus service exec" >/dev/null 2>&1; then
            pass "app-handler binary includes dbus service exec spawn" "Console/kgx desktop Exec or dbus launch path present"
        else
            warn "app-handler binary includes dbus service exec spawn" "missing dbus service exec spawn trace -- DBusActivatable apps may log success without opening; hotfix atomos-app-handler"
        fi
    fi
else
    warn "app-handler binary present" "$APP_HANDLER_BIN missing/not +x"
fi
if [ -x "$CHAT_UI_BIN" ]; then
    pass "chat-ui app-grid owner present" "$CHAT_UI_BIN"
else
    warn "chat-ui app-grid owner present" "$CHAT_UI_BIN missing -- the app grid is owned by atomos-overview-chat-ui; without it there are no tiles to tap"
fi

CHAT_UI_PIDS="$(pgrep -f "$CHAT_UI_BIN" 2>/dev/null || true)"
if [ -n "$CHAT_UI_PIDS" ]; then
    pass "chat-ui running" "pid(s): $CHAT_UI_PIDS"
else
    warn "chat-ui running" "no $CHAT_UI_BIN process -- run diagnose-app-handler.sh; the grid will not be visible/clickable"
fi

# ----- Stage 2: desktop entry database (Exec=/TryExec= resolution) -----
# This is the heart of the SOME-apps-do-not-open symptom: GIO DesktopAppInfo
# launches the Exec= command; a missing binary makes that one app silently
# fail to open while every other tile works.
header "Desktop entry Exec=/TryExec= resolution"
DESKTOP_DIRS="/usr/share/applications /usr/local/share/applications"
[ -d "$USER_HOME/.local/share/applications" ] && DESKTOP_DIRS="$DESKTOP_DIRS $USER_HOME/.local/share/applications"
info "scanned directories" "$DESKTOP_DIRS"

total=0
broken=0
hidden=0
dbus_apps=0
for dir in $DESKTOP_DIRS; do
    [ -d "$dir" ] || continue
    for df in "$dir"/*.desktop; do
        [ -f "$df" ] || continue
        # GIO should_show() filtering: skip NoDisplay/Hidden entries -- those
        # never appear as tiles, so a missing Exec= there is not a user-visible
        # failure.
        if grep -qi "^NoDisplay=true" "$df" 2>/dev/null; then hidden=$((hidden+1)); continue; fi
        if grep -qi "^Hidden=true" "$df" 2>/dev/null; then hidden=$((hidden+1)); continue; fi
        # Only the [Desktop Entry] Type=Application entries are launchable.
        if grep -qi "^Type=" "$df" 2>/dev/null && ! grep -qi "^Type=Application" "$df" 2>/dev/null; then
            continue
        fi
        total=$((total+1))
        base="$(basename "$df")"

        # TryExec=: if present and unresolvable, GIO hides the entry entirely.
        tryexec_line="$(grep -m1 "^TryExec=" "$df" 2>/dev/null | head -n1 || true)"
        if [ -n "$tryexec_line" ]; then
            tryexec="${tryexec_line#TryExec=}"
            case "$tryexec" in
                /*) if [ ! -x "$tryexec" ]; then warn "TryExec missing" "$base -- TryExec=$tryexec not executable; GIO hides this tile entirely"; broken=$((broken+1)); continue; fi ;;
                *)  if ! command -v "$tryexec" >/dev/null 2>&1; then warn "TryExec missing" "$base -- TryExec=$tryexec not on PATH; GIO hides this tile entirely"; broken=$((broken+1)); continue; fi ;;
            esac
        fi

        # DBus-activatable apps do not spawn Exec= directly -- GIO talks to the
        # org.freedesktop.Application D-Bus service. Validate the service file
        # instead of the Exec binary.
        if grep -qi "^DBusActivatable=true" "$df" 2>/dev/null; then
            dbus_apps=$((dbus_apps+1))
            svc_id="${base%.desktop}"
            svc_file=""
            for sdir in /usr/share/dbus-1/services /usr/local/share/dbus-1/services; do
                [ -f "$sdir/$svc_id.service" ] && svc_file="$sdir/$svc_id.service"
            done
            if [ -n "$svc_file" ]; then
                info "DBus-activatable app" "$base -> $svc_file"
            else
                warn "DBus-activatable service missing" "$base declares DBusActivatable=true but no $svc_id.service in /usr/share/dbus-1/services -- GIO D-Bus launch will fail; app will not open"
                broken=$((broken+1))
            fi
            continue
        fi

        exec_line="$(grep -m1 "^Exec=" "$df" 2>/dev/null | head -n1 || true)"
        if [ -z "$exec_line" ]; then
            warn "no Exec= and not DBusActivatable" "$base -- nothing to launch"
            broken=$((broken+1))
            continue
        fi
        cmd="${exec_line#Exec=}"
        # First whitespace-delimited token is the program; field codes (%U %f
        # %i ...) only appear as later args.
        bin="${cmd%% *}"
        case "$bin" in
            /*) if [ ! -x "$bin" ]; then warn "Exec binary missing" "$base -- Exec=$bin not executable; THIS app will not open"; broken=$((broken+1)); fi ;;
            *)  if ! command -v "$bin" >/dev/null 2>&1; then warn "Exec binary missing" "$base -- Exec=$bin not on PATH; THIS app will not open"; broken=$((broken+1)); fi ;;
        esac
    done
done
info "desktop entry tally" "launchable=$total broken=$broken hidden/no-display=$hidden dbus-activatable=$dbus_apps"
if [ "$total" -eq 0 ]; then
    warn "no launchable desktop entries found" "no Type=Application *.desktop in $DESKTOP_DIRS -- the grid will be empty (nothing to open)"
elif [ "$broken" -eq 0 ]; then
    pass "all launchable desktop entries resolve" "$total entries, every Exec=/TryExec=/DBus target present"
else
    warn "broken desktop entries" "$broken of $total launchable entries point at a missing target (see FAIL lines above) -- those are the apps that do not open"
fi

# ----- Stage 3: session env for spawned children -----
# The launched app inherits WAYLAND_DISPLAY / XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS
# from whichever process spawned it (app-handler launch, itself spawned by
# chat-ui). Missing WAYLAND_DISPLAY -> the app starts but cannot map a window.
# Missing DBUS_SESSION_BUS_ADDRESS -> GIO cannot D-Bus-activate the 16
# DBusActivatable apps (it has no session bus to send Activate to); plain
# Exec= apps still open, which presents exactly as "some apps do not open".
# We also stash the resolved values so the live launch test below can
# reproduce the chat-ui real environment instead of the bare ssh shell.
header "Session env available to spawned apps (Wayland + D-Bus)"
ENV_SRC_PID="$(echo "$CHAT_UI_PIDS" | awk "{print \$1}")"
[ -n "$ENV_SRC_PID" ] || ENV_SRC_PID="$(pgrep -f "$APP_HANDLER_BIN" 2>/dev/null | head -n1 || true)"
SPAWNER_WAYLAND_DISPLAY=""
SPAWNER_XDG_RUNTIME_DIR=""
SPAWNER_DBUS_SESSION=""
SPAWNER_GDK_BACKEND=""
SPAWNER_DISPLAY=""
if [ -n "$ENV_SRC_PID" ] && [ -r "/proc/$ENV_SRC_PID/environ" ]; then
    env_lines="$(tr "\000" "\n" < "/proc/$ENV_SRC_PID/environ" 2>/dev/null || true)"
    SPAWNER_WAYLAND_DISPLAY="$(printf "%s\n" "$env_lines" | sed -n "s/^WAYLAND_DISPLAY=//p" | head -n1)"
    SPAWNER_XDG_RUNTIME_DIR="$(printf "%s\n" "$env_lines" | sed -n "s/^XDG_RUNTIME_DIR=//p" | head -n1)"
    SPAWNER_DBUS_SESSION="$(printf "%s\n" "$env_lines" | sed -n "s/^DBUS_SESSION_BUS_ADDRESS=//p" | head -n1)"
    SPAWNER_GDK_BACKEND="$(printf "%s\n" "$env_lines" | sed -n "s/^GDK_BACKEND=//p" | head -n1)"
    SPAWNER_DISPLAY="$(printf "%s\n" "$env_lines" | sed -n "s/^DISPLAY=//p" | head -n1)"
    env_dump="$(printf "%s\n" "$env_lines" | grep -E "^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|GDK_BACKEND|DISPLAY)=" | tr "\n" " " || true)"
    info "spawner env (pid $ENV_SRC_PID)" "${env_dump:-<no relevant vars>}"
    if [ -n "$SPAWNER_WAYLAND_DISPLAY" ]; then
        pass "spawner exports WAYLAND_DISPLAY" "children can reach the compositor"
    else
        warn "spawner exports WAYLAND_DISPLAY" "missing -- launched apps cannot bind Wayland and will exit without a window"
    fi
    if [ -n "$SPAWNER_XDG_RUNTIME_DIR" ]; then
        pass "spawner exports XDG_RUNTIME_DIR"
    else
        warn "spawner exports XDG_RUNTIME_DIR" "missing -- wayland socket path is undiscoverable for children"
    fi
    if [ -n "$SPAWNER_DBUS_SESSION" ]; then
        pass "spawner exports DBUS_SESSION_BUS_ADDRESS" "GIO can D-Bus-activate DBusActivatable apps"
    elif [ "$dbus_apps" -gt 0 ]; then
        warn "spawner exports DBUS_SESSION_BUS_ADDRESS" "MISSING from the chat-ui/app-handler environ, but $dbus_apps of $total launchable apps are DBusActivatable=true. GIO has no session bus to send org.freedesktop.Application.Activate to, so those apps silently fail to open while plain Exec= apps still launch -- the classic \"some apps do not open\" split. Likely the chat-ui autostart/launcher does not import DBUS_SESSION_BUS_ADDRESS (dbus-run-session / dbus-update-activation-environment not wired into the phosh session). Check: tr \\\\0 \\\\n < /proc/$ENV_SRC_PID/environ | grep DBUS"
    else
        info "spawner exports DBUS_SESSION_BUS_ADDRESS" "missing, but no DBusActivatable apps detected, so not fatal here"
    fi
    if [ "$dbus_apps" -gt 0 ]; then
        if command -v dbus-update-activation-environment >/dev/null 2>&1; then
            pass "dbus-update-activation-environment present" "app-handler can push WAYLAND_DISPLAY into dbus activation env before DBusActivatable launches"
        else
            warn "dbus-update-activation-environment present" "missing -- DBusActivatable apps may log [launch: spawned] but never map a window because activated services lack WAYLAND_DISPLAY (Exec= apps like Firefox still work)"
        fi
    fi
else
    info "spawner env" "no chat-ui/app-handler process to read environ from; start the session and re-run"
fi

# ----- Stage 4: foreign-toplevel manager (ActivateExisting de-dup path) -----
# plan_launch() activates an existing toplevel instead of spawning when one is
# already open. If the compositor does not advertise the manager, the de-dup
# snapshot is empty -> app-handler always SpawnNew (usually harmless) but a
# broken manager can also make "activate existing" silently no-op.
header "Compositor foreign-toplevel manager (activate-existing path)"
PHOSH_PID="$(pgrep -x phosh 2>/dev/null | head -n1 || true)"
[ -n "$PHOSH_PID" ] || PHOSH_PID="$(pgrep -f "(^|/)phosh(\$|[[:space:]])" 2>/dev/null | head -n1 || true)"
if command -v wayland-info >/dev/null 2>&1 && [ -n "$PHOSH_PID" ] && [ -r "/proc/$PHOSH_PID/environ" ]; then
    wl_runtime="$(tr "\000" "\n" < "/proc/$PHOSH_PID/environ" | awk -F= "/^XDG_RUNTIME_DIR=/ {print \$2; exit}")"
    wl_display="$(tr "\000" "\n" < "/proc/$PHOSH_PID/environ" | awk -F= "/^WAYLAND_DISPLAY=/ {print \$2; exit}")"
    if [ -n "$wl_runtime" ] && [ -n "$wl_display" ]; then
        if XDG_RUNTIME_DIR="$wl_runtime" WAYLAND_DISPLAY="$wl_display" wayland-info 2>/dev/null | grep -q zwlr_foreign_toplevel_manager_v1; then
            pass "compositor advertises zwlr_foreign_toplevel_manager_v1"
        else
            warn "compositor advertises zwlr_foreign_toplevel_manager_v1" "missing -- app-handler cannot see existing windows; activate-existing de-dup is disabled (re-tapping an open app may spawn duplicates or no-op)"
        fi
    else
        info "wayland-info" "no WAYLAND_DISPLAY/XDG_RUNTIME_DIR in phosh environ"
    fi
else
    info "wayland-info" "not installed or no phosh pid; skipping (apk add wayland-utils to enable)"
fi

# ----- Stage 5: launch evidence in the logs -----
header "Launch evidence (chat-ui + app-handler logs)"
saw_dispatch=0
for log in /run/user/*/atomos-overview-chat-ui.log; do
    [ -f "$log" ] || continue
    info "chat-ui log" "$log"
    # The launcher chat-ui spawns (`atomos-app-handler launch <id>`) is a child
    # of chat-ui, so the BINARY trace (`atomos-app-handler: launch: spawned new
    # app id=`), GIO errors (`unknown desktop app id`), and any anyhow `Error:`
    # all inherit chat-ui stderr and land HERE -- not in atomos-app-handler.log
    # (which only captures the autostarted --start handle-bar process).
    if grep -qE "dispatching launch via|atomos-app-handler: launch:|unknown desktop app id|^Error:" "$log" 2>/dev/null; then
        saw_dispatch=1
        echo "----8<---- launch-related lines (last 20) ----8<----"
        grep -nE "dispatching launch via|spawn of .* failed|failed launching|falling back to gio|atomos-app-handler: launch:|unknown desktop app id|^Error:" "$log" 2>/dev/null | tail -n 20 || true
        echo "----8<----"
    fi
    if grep -q "spawn of .* failed" "$log" 2>/dev/null; then
        warn "chat-ui logged a failed spawn" "see [spawn of <launcher> failed] in $log -- the app-handler launcher could not be exec-ed; chat-ui fell back to gio"
    fi
    if grep -q "failed launching" "$log" 2>/dev/null; then
        warn "chat-ui logged a failed gio launch" "see [failed launching] in $log -- GIO could not start the app (missing Exec binary or D-Bus service)"
    fi
    if grep -q "unknown desktop app id" "$log" 2>/dev/null; then
        warn "launch hit unknown desktop app id" "see [unknown desktop app id] in $log -- the binary could not resolve the .desktop id chat-ui passed; entry missing or id != file name"
    fi
    # dispatch counted but no spawn-success trace -> the launch errored after
    # dispatch (most often a GIO D-Bus activation failure for a DBus app).
    if grep -q "dispatching launch via" "$log" 2>/dev/null \
        && ! grep -q "atomos-app-handler: launch: spawned new app id=" "$log" 2>/dev/null \
        && ! grep -q "atomos-app-handler: launch: activated existing toplevel" "$log" 2>/dev/null; then
        warn "dispatch logged but no launch:spawned/activated trace" "chat-ui dispatched a launch but the binary never logged [launch: spawned new app id=] or [launch: activated existing toplevel] in $log. The launch errored between dispatch and spawn -- usually gio could not activate the app (DBusActivatable app + missing DBUS_SESSION_BUS_ADDRESS, see Stage 3). Re-run with ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID set to capture the exact error."
    fi
    if grep -q "atomos-app-handler: launch: spawned new app id=" "$log" 2>/dev/null \
        || grep -q "atomos-app-handler: launch: activated existing toplevel" "$log" 2>/dev/null; then
        if ! grep -q "launch: promoting overview-chat-ui to bottom layer" "$log" 2>/dev/null; then
            warn "launch succeeded without chat-ui layer promotion" "log shows [launch: spawned/activated] but not [launch: promoting overview-chat-ui to bottom layer] -- rebuild atomos-app-handler with run_launch_once relayer fix"
        fi
        if ! grep -q "dismissing app sheet for launch" "$log" 2>/dev/null; then
            info "app sheet dismiss trace" "no [dismissing app sheet for launch] yet -- rebuild atomos-overview-chat-ui so tile taps collapse the overlay sheet before spawn"
        fi
        if grep -q "atomos-app-handler: launch: spawned new app id=org.gnome.Console.desktop" "$log" 2>/dev/null \
            || grep -q "atomos-app-handler: launch: spawned new app id=org.gnome.Settings.desktop" "$log" 2>/dev/null; then
            if strings "$APP_HANDLER_BIN" 2>/dev/null | grep -q "Option::<&gio::AppLaunchContext>::None"; then
                warn "DBusActivatable launch missing GdkAppLaunchContext" "log shows spawned for a DBusActivatable app but the app-handler binary still passes None to gio::AppInfo::launch — GIO returns Ok but the window never appears (Firefox Exec= apps still work). Rebuild atomos-app-handler with display_app_launch_context fix."
            fi
        fi
    fi
done
if [ "$saw_dispatch" = "0" ]; then
    info "chat-ui launch dispatch" "no [dispatching launch via] line yet -- tap an app tile, then re-run (or chat-ui log is on a different /run/user mount)"
fi

header "Chat-ui layer vs foreground app (overlay hides xdg-toplevel)"
CHAT_LAYER_FILE=""
for f in /run/user/*/atomos-overview-chat-ui.layer; do
    [ -f "$f" ] || continue
    CHAT_LAYER_FILE="$f"
    break
done
if [ -n "$CHAT_LAYER_FILE" ]; then
    layer="$(cat "$CHAT_LAYER_FILE" 2>/dev/null || true)"
    info "chat-ui layer file" "$CHAT_LAYER_FILE -> ${layer:-<empty>}"
    saw_launch_ok=0
    for log in /run/user/*/atomos-overview-chat-ui.log; do
        if grep -q "atomos-app-handler: launch: spawned new app id=" "$log" 2>/dev/null \
            || grep -q "atomos-app-handler: launch: activated existing toplevel" "$log" 2>/dev/null; then
            saw_launch_ok=1
            break
        fi
    done
    if [ "$layer" = "overlay" ] && [ "$saw_launch_ok" = "1" ]; then
        warn "chat-ui still on overlay after successful launch" "gio logged success but layer=overlay keeps the app-grid sheet above xdg-toplevel windows -- the app is running but invisible. Hotfix overview-chat-ui (dismiss sheet on tile tap) and atomos-app-handler (promote chat-ui to bottom after launch)."
    elif [ "$saw_launch_ok" = "1" ]; then
        pass "chat-ui layer allows foreground apps" "layer=${layer:-bottom}"
    fi
else
    info "chat-ui layer file" "missing (launcher has not written atomos-overview-chat-ui.layer yet)"
fi

for log in /run/user/*/atomos-app-handler.log; do
    [ -f "$log" ] || continue
    info "app-handler log" "$log"
    launch_lines="$(grep -E "launch: (spawned new app id=|activated existing toplevel)|launch requires an app id|unknown desktop app id" "$log" 2>/dev/null | tail -n 10 || true)"
    if [ -n "$launch_lines" ]; then
        echo "----8<---- last 10 launch lines ----8<----"
        printf "%s\n" "$launch_lines"
        echo "----8<----"
    fi
    if grep -q "unknown desktop app id" "$log" 2>/dev/null; then
        warn "app-handler hit unknown desktop app id" "see [unknown desktop app id] in $log -- GIO could not resolve the .desktop id passed by chat-ui; the entry is missing or its id does not match the file name"
    fi
    if grep -q "launch requires an app id" "$log" 2>/dev/null; then
        warn "app-handler got empty app id" "see [launch requires an app id] in $log -- the tile passed an empty id (broken desktop entry metadata)"
    fi
done

# ----- Stage 6: optional live launch test -----
# Reproduce the real tap by invoking the launcher with the chat-ui resolved
# session env (Wayland + D-Bus) rather than the bare ssh shell, which has no
# WAYLAND_DISPLAY/DBUS_SESSION_BUS_ADDRESS and would fail for unrelated reasons.
header "Live launch test"
if [ -n "${ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID:-}" ]; then
    TEST_ID="${ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID}"
    info "live launch" "invoking $LAUNCHER launch $TEST_ID with chat-ui session env (WAYLAND_DISPLAY=${SPAWNER_WAYLAND_DISPLAY:-<none>} XDG_RUNTIME_DIR=${SPAWNER_XDG_RUNTIME_DIR:-<none>} DBUS_SESSION_BUS_ADDRESS=${SPAWNER_DBUS_SESSION:+<set>}${SPAWNER_DBUS_SESSION:-<none>})"
    if [ -x "$LAUNCHER" ]; then
        saved_wayland="${WAYLAND_DISPLAY-}"
        saved_xdg="${XDG_RUNTIME_DIR-}"
        saved_dbus="${DBUS_SESSION_BUS_ADDRESS-}"
        saved_gdk="${GDK_BACKEND-}"
        saved_display="${DISPLAY-}"
        [ -n "$SPAWNER_WAYLAND_DISPLAY" ] && WAYLAND_DISPLAY="$SPAWNER_WAYLAND_DISPLAY"
        [ -n "$SPAWNER_XDG_RUNTIME_DIR" ] && XDG_RUNTIME_DIR="$SPAWNER_XDG_RUNTIME_DIR"
        [ -n "$SPAWNER_DBUS_SESSION" ] && DBUS_SESSION_BUS_ADDRESS="$SPAWNER_DBUS_SESSION"
        [ -n "$SPAWNER_GDK_BACKEND" ] && GDK_BACKEND="$SPAWNER_GDK_BACKEND"
        [ -n "$SPAWNER_DISPLAY" ] && DISPLAY="$SPAWNER_DISPLAY"
        export WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS GDK_BACKEND DISPLAY
        if "$LAUNCHER" launch "$TEST_ID" >/tmp/atomos-launch-test.out 2>&1; then
            pass "live launch exit 0" "$TEST_ID -- binary trace: $(grep -E "atomos-app-handler: launch:|unknown desktop app id|^Error:" /tmp/atomos-launch-test.out 2>/dev/null | tr "\n" " " | head -c 400)"
            # GIO returns Ok for DBusActivatable apps once D-Bus Activate succeeds,
            # even when the service never maps a Wayland window. Verify presence.
            TEST_BASE="${TEST_ID%.desktop}"
            TEST_IS_DBUS=0
            for df in /usr/share/applications/"$TEST_ID" /usr/local/share/applications/"$TEST_ID" "$USER_HOME/.local/share/applications/$TEST_ID"; do
                [ -f "$df" ] || continue
                if grep -qi "^DBusActivatable=true" "$df" 2>/dev/null; then
                    TEST_IS_DBUS=1
                fi
                break
            done
            saw_process=0
            saw_bus=0
            launch_pid=""
            wait_loops=8
            [ "$TEST_IS_DBUS" = "1" ] && wait_loops=12
            wait_i=0
            poll_busctl() {
                [ -n "$SPAWNER_XDG_RUNTIME_DIR" ] || return 1
                if [ -n "$SPAWNER_DBUS_SESSION" ]; then
                    env XDG_RUNTIME_DIR="$SPAWNER_XDG_RUNTIME_DIR" \
                        "DBUS_SESSION_BUS_ADDRESS=$SPAWNER_DBUS_SESSION" \
                        busctl --user list 2>/dev/null
                else
                    env XDG_RUNTIME_DIR="$SPAWNER_XDG_RUNTIME_DIR" \
                        busctl --user list 2>/dev/null
                fi
            }
            while [ "$wait_i" -lt "$wait_loops" ]; do
                if command -v busctl >/dev/null 2>&1 && poll_busctl | grep -Fq "$TEST_BASE"; then
                    saw_bus=1
                    launch_pid="$(poll_busctl | awk -v base="$TEST_BASE" "\$1==base {print \$2; exit}")"
                fi
                if [ "$TEST_BASE" = "org.gnome.Console" ]; then
                    if pgrep -x kgx >/dev/null 2>&1; then
                        saw_process=1
                        launch_pid="$(pgrep -x kgx 2>/dev/null | head -n1 || true)"
                    elif pgrep -f "gnome-console" >/dev/null 2>&1; then
                        saw_process=1
                        launch_pid="$(pgrep -f "gnome-console" 2>/dev/null | head -n1 || true)"
                    fi
                elif [ -n "$launch_pid" ]; then
                    saw_process=1
                else
                    for candidate in $(pgrep -f "$TEST_BASE" 2>/dev/null || true); do
                        comm="$(ps -o comm= "$candidate" 2>/dev/null || true)"
                        case "$comm" in
                            *bash*|*sh|ssh|sshpass) continue ;;
                        esac
                        saw_process=1
                        launch_pid="$candidate"
                        break
                    done
                fi
                if [ "$saw_process" = "1" ] || [ "$saw_bus" = "1" ]; then
                    break
                fi
                wait_i=$((wait_i + 1))
                sleep 1
            done
            if [ "$saw_process" = "1" ] || [ "$saw_bus" = "1" ]; then
                pass "live launch presence" "$TEST_ID -- process=${saw_process} session-bus=${saw_bus}"
                if [ -n "$launch_pid" ] && [ -r "/proc/$launch_pid/environ" ]; then
                    if tr "\000" "\n" < "/proc/$launch_pid/environ" 2>/dev/null | grep -q "^WAYLAND_DISPLAY="; then
                        pass "live launch process env" "pid=$launch_pid has WAYLAND_DISPLAY"
                    elif [ "$TEST_IS_DBUS" = "1" ] && [ "$saw_bus" = "1" ]; then
                        pass "live launch process env" "pid=$launch_pid on session bus (DBus activation env is not always visible in /proc/environ)"
                    elif [ "$TEST_IS_DBUS" = "1" ]; then
                        warn "live launch process env" "pid=$launch_pid missing WAYLAND_DISPLAY -- DBus activation env may not be synced; rebuild atomos-app-handler with dbus-update-activation-environment + launch_uris_as_manager fix"
                    fi
                fi
            elif [ "$TEST_IS_DBUS" = "1" ]; then
                warn "live launch GIO success but app absent" "$TEST_ID -- exit 0 and [launch: spawned] but no $TEST_BASE/kgx process or session-bus name within ${wait_loops}s. Full trace: $(tr "\n" " " </tmp/atomos-launch-test.out 2>/dev/null | head -c 500). Hotfix atomos-app-handler (expect [launch: syncing session env] and [launch: dbus activatable spawning desktop Exec kgx] or session-bus owner)."
            else
                info "live launch presence" "$TEST_ID -- no process/bus match within ${wait_loops}s (Exec= app may have exited quickly; check the device screen manually)"
            fi
        else
            rc=$?
            warn "live launch failed" "$TEST_ID -- launcher exited rc=$rc; output: $(cat /tmp/atomos-launch-test.out 2>/dev/null | tr "\n" " " | head -c 600)"
        fi
        if [ -z "$SPAWNER_DBUS_SESSION" ]; then
            info "live launch caveat" "DBUS_SESSION_BUS_ADDRESS was not available from the spawner environ, so a DBusActivatable test app may still fail here even if the real chat-ui process has it. Cross-check the chat-ui log trace above."
        fi
    else
        warn "live launch" "$LAUNCHER not executable; cannot run the test"
    fi
else
    info "live launch" "skipped -- set ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID=<id> (e.g. org.gnome.Settings.desktop) to actually invoke the launcher with chat-ui session env and capture the binary trace + exit code"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: all launch-chain checks PASS."
    exit 0
else
    echo "RESULT: at least one launch-chain check FAILED -- fix the FAIL lines top-to-bottom. For DBusActivatable apps (Console, Settings, …), GIO exit 0 does not mean a window appeared: read the live launch presence lines."
    exit 1
fi
'

# Host-side guard: the remote blob is assigned inside a single-quoted literal;
# any ASCII single quote inside it truncates the assignment and breaks SSH.
case $REMOTE_SCRIPT in *"'"*)
    echo "diagnose-app-launch.sh: REMOTE_SCRIPT contains a single quote; fix quoting before shipping" >&2
    exit 1
    ;;
esac

# Forward the optional live-test selector into the remote environment.
REMOTE_SCRIPT="ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID=\"${LAUNCH_TEST_APP_ID}\"
export ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID
${REMOTE_SCRIPT}"

echo "Running app-launch diagnostics on $SSH_TARGET (port $SSH_PORT)..."
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
$REMOTE_SCRIPT
EOF
