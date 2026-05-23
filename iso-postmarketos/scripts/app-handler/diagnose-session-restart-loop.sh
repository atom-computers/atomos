#!/bin/bash
# Diagnose Phosh "lockscreen -> load (shrinks display) -> lockscreen" cycle.
#
# Symptom this targets:
#   - greetd shows the lockscreen
#   - user unlocks (or auto-login fires)
#   - Phosh session briefly loads, the host display resolution drops back
#     to console / firmware default
#   - greetd respawns the lockscreen
#   - the cycle repeats every few seconds
#
# What this script does (over SSH, on the device):
#   1. Records baseline pids and a "since" timestamp.
#   2. Polls greetd / phoc / phosh / gnome-session / atomos-app-handler
#      pids every second for OBSERVE_SECONDS (default 30s).
#   3. Logs each pid transition with a wall-clock timestamp so the cycle
#      period and which process dies first are both visible.
#   4. After the window: greps journalctl + /var/log/messages + dmesg
#      for crash/exit markers since baseline and prints them.
#   5. Lists coredumps newer than baseline.
#   6. Prints a one-line verdict suggesting which side died first.
#
# Pairs with diagnose-session-boot-loop.sh:
#   diagnose-session-boot-loop      "session never came up"     one-shot
#   diagnose-session-restart-loop   "session comes up and dies" follow-along
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 \
#   bash iso-postmarketos/scripts/app-handler/diagnose-session-restart-loop.sh \
#     iso-postmarketos/config/arm64-virt.env user@localhost
#
# Env knobs:
#   ATOMOS_DIAG_OBSERVE_SECONDS   poll window length (default 30)
#   ATOMOS_DIAG_POLL_INTERVAL     poll interval in seconds (default 1)
#   ATOMOS_DEVICE_SSH_PORT        SSH port to the guest (default 2222)
#   ATOMOS_DEVICE_SSHPASS         SSH password (defaults to PMOS_INSTALL_PASSWORD)
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
OBSERVE_SECONDS="${ATOMOS_DIAG_OBSERVE_SECONDS:-30}"
POLL_INTERVAL="${ATOMOS_DIAG_POLL_INTERVAL:-1}"

SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR)

REMOTE_LIB="$(cat "$ROOT_DIR/scripts/app-handler/_lib-post-unlock-runtime-checks.remote.sh")"

# Build the remote script in two parts:
#   1. Knob exports (interpolated from this host's env).
#   2. The remote body, captured verbatim from a *single-quoted* heredoc
#      so no special characters need backslash-escaping.
REMOTE_PROLOGUE=$(printf '%s\n' \
    "OBSERVE_SECONDS=${OBSERVE_SECONDS}" \
    "POLL_INTERVAL=${POLL_INTERVAL}")

REMOTE_BODY=$(cat <<'REMOTE_SH'
set -u

pass() { printf 'PASS  %s%s\n' "$1" "${2:+ -- $2}"; }
warn() { printf 'FAIL  %s -- %s\n' "$1" "${2:-}"; }
info() { printf 'INFO  %s -- %s\n' "$1" "${2:-}"; }
header() { printf '\n=== %s ===\n' "$1"; }
tick()   { printf '%s  %s\n' "$(date +%H:%M:%S)" "$1"; }

# ----- begin inlined _lib-post-unlock-runtime-checks.remote.sh -----
__REMOTE_LIB__
# ----- end inlined library -----

TS_BEGIN="$(date -Iseconds 2>/dev/null || date)"
touch /tmp/.atomos-diag-anchor 2>/dev/null || true

header "Baseline"
info "ssh user"           "$(id -un 2>/dev/null || echo unknown) uid=$(id -u 2>/dev/null || echo ?)"
info "observe window"     "${OBSERVE_SECONDS}s @ ${POLL_INTERVAL}s interval"
info "begin"              "$TS_BEGIN"

# ── Environment inventory ────────────────────────────────────────────────
# Captures the three classes of runtime failure most likely to keep
# greetd→phoc→phrog cycling without an actual crash:
#   1. Mesa userspace DRI driver missing or wrong version
#      → phoc logs "virtio_gpu: driver missing" + EGL_NOT_INITIALIZED
#   2. seatd socket unreadable by the greetd / phosh user
#      → phoc logs "[libseat] Could not connect to /run/seatd.sock: Permission denied"
#   3. greetd config still points at phrog with no autologin
#      → user types creds, session=phrog cycles, never reaches phosh-session

header "Mesa DRI / GBM inventory"
if [ -d /usr/lib/dri ]; then
    _dri_list="$(ls /usr/lib/dri 2>/dev/null | tr '\n' ' ')"
    info "/usr/lib/dri" "$_dri_list"
    if printf '%s' "$_dri_list" | grep -qE 'virtio_gpu(_dri)?\.so|virtio-gpu'; then
        pass "virtio_gpu userspace DRI" "present"
    else
        warn "virtio_gpu userspace DRI" "NOT in /usr/lib/dri (Mesa will log 'virtio_gpu: driver missing'); install mesa-dri-gallium"
    fi
else
    warn "/usr/lib/dri" "directory missing — Mesa gallium drivers not installed"
fi
if command -v apk >/dev/null 2>&1; then
    for pkg in mesa-dri-gallium mesa-gbm mesa-egl mesa-gl mesa-vulkan-swrast libdrm; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            info "apk $pkg" "$(apk info "$pkg" 2>/dev/null | head -n1 | tr -d '\n')"
        else
            warn "apk $pkg" "NOT installed"
        fi
    done
fi
[ -e /dev/dri/card0 ] && info "/dev/dri/card0" "$(ls -l /dev/dri/card0 2>/dev/null)" \
    || warn "/dev/dri/card0" "missing — DRM device not created by kernel"
[ -e /dev/dri/renderD128 ] && info "/dev/dri/renderD128" "$(ls -l /dev/dri/renderD128 2>/dev/null)" \
    || info "/dev/dri/renderD128" "missing — no render node (fine if only KMS scanout is needed)"
for _drm in /sys/class/drm/card*; do
    [ -d "$_drm" ] || continue
    _drv="$(readlink "$_drm/device/driver" 2>/dev/null | awk -F/ '{print $NF}')"
    info "$(basename "$_drm") driver" "${_drv:-<unbound>}"
done
if command -v lsmod >/dev/null 2>&1; then
    _virtio="$(lsmod 2>/dev/null | awk '/^virtio_gpu|^virtio_dma|^virtio_pci/ {print $1}' | tr '\n' ' ')"
    if [ -n "$_virtio" ]; then
        pass "kernel virtio modules loaded" "$_virtio"
    else
        warn "kernel virtio modules loaded" "virtio_gpu not in lsmod — check /etc/modules + initramfs"
    fi
fi

header "seatd socket + groups"
if [ -S /run/seatd.sock ]; then
    info "/run/seatd.sock" "$(ls -l /run/seatd.sock 2>/dev/null)"
else
    warn "/run/seatd.sock" "missing — seatd service is not running"
fi
if command -v rc-service >/dev/null 2>&1; then
    info "rc-service seatd" "$(rc-service seatd status 2>&1 | head -n1 | tr -d '\n')"
fi
for _u in greetd user; do
    if getent passwd "$_u" >/dev/null 2>&1; then
        info "id $_u" "$(id "$_u" 2>/dev/null || echo '?')"
    fi
done
for _g in seat video render input wheel; do
    if getent group "$_g" >/dev/null 2>&1; then
        info "group $_g" "$(getent group "$_g")"
    fi
done

header "greetd / wayland session wiring"
if [ -f /etc/greetd/config.toml ]; then
    info "/etc/greetd/config.toml"
    grep -E '^(command|user|vt|\[)' /etc/greetd/config.toml 2>/dev/null | sed 's/^/    /' | head -n 20
else
    warn "/etc/greetd/config.toml" "missing"
fi
if [ -f /etc/phrog/greetd-config.toml ]; then
    info "/etc/phrog/greetd-config.toml"
    grep -E '^(command|user|vt|\[)' /etc/phrog/greetd-config.toml 2>/dev/null | sed 's/^/    /' | head -n 20
fi
if [ -f /etc/conf.d/greetd ]; then
    info "/etc/conf.d/greetd" "$(grep -vE '^\s*(#|$)' /etc/conf.d/greetd 2>/dev/null | tr '\n' ' ')"
fi
if [ -d /usr/share/wayland-sessions ]; then
    info "/usr/share/wayland-sessions" "$(ls /usr/share/wayland-sessions 2>/dev/null | tr '\n' ' ')"
    if [ -f /usr/share/wayland-sessions/phosh.desktop ]; then
        info "  phosh.desktop Exec" "$(grep '^Exec=' /usr/share/wayland-sessions/phosh.desktop 2>/dev/null | head -n1)"
    else
        warn "/usr/share/wayland-sessions/phosh.desktop" "missing — greetd cannot launch the Phosh shell"
    fi
fi
if [ -f /etc/atomos/autologin-user ]; then
    pass "autologin marker" "$(cat /etc/atomos/autologin-user) (image built with PMOS_AUTOLOGIN=1)"
else
    info "autologin marker" "/etc/atomos/autologin-user absent — image uses phrog greeter (lockscreen)"
fi
if [ -f /etc/atomos/phosh-profile.env ]; then
    info "/etc/atomos/phosh-profile.env"
    sed 's/^/    /' /etc/atomos/phosh-profile.env 2>/dev/null | head -n 20
fi

phoc0="$(atomos_find_phoc_pid)"
phosh0="$(atomos_find_phosh_pid)"
gs0="$(atomos_find_gnome_session_phosh_pid)"
greetd0="$(pgrep -d, -f greetd 2>/dev/null || true)"
handler0="$(atomos_find_handler_pids)"
info "phoc baseline"      "${phoc0:-<missing>}"
info "phosh baseline"     "${phosh0:-<missing>}"
info "gnome-session base" "${gs0:-<missing>}"
info "greetd baseline"    "${greetd0:-<missing>}"
info "handler baseline"   "${handler0:-<none>}"

phoc_births=0; phoc_deaths=0; phoc_restarts=0
phosh_births=0; phosh_deaths=0; phosh_restarts=0
gs_restarts=0; greetd_restarts=0
death_order_phoc_first=0
death_order_phosh_first=0
last_phoc_death_ts=""
last_phosh_death_ts=""

phoc_last="$phoc0"
phosh_last="$phosh0"
gs_last="$gs0"
greetd_last="$greetd0"

emit_transition() {
    _tag="$1"; _old="$2"; _new="$3"
    if [ -z "$_old" ] && [ -n "$_new" ]; then
        tick "+ ${_tag} born pid=${_new}"
    elif [ -n "$_old" ] && [ -z "$_new" ]; then
        tick "- ${_tag} died pid=${_old}"
    elif [ "$_old" != "$_new" ]; then
        tick "~ ${_tag} restarted ${_old} -> ${_new}"
    fi
}

header "Observation loop"
elapsed=0
while [ "$elapsed" -lt "$OBSERVE_SECONDS" ]; do
    phoc_now="$(atomos_find_phoc_pid)"
    phosh_now="$(atomos_find_phosh_pid)"
    gs_now="$(atomos_find_gnome_session_phosh_pid)"
    greetd_now="$(pgrep -d, -f greetd 2>/dev/null || true)"

    if [ "$phoc_now" != "$phoc_last" ]; then
        emit_transition "phoc" "$phoc_last" "$phoc_now"
        if [ -z "$phoc_now" ] && [ -n "$phoc_last" ]; then
            phoc_deaths=$((phoc_deaths + 1))
            last_phoc_death_ts="$(date +%s)"
            if [ -n "$last_phosh_death_ts" ] && \
               [ $((last_phoc_death_ts - last_phosh_death_ts)) -ge 0 ] && \
               [ $((last_phoc_death_ts - last_phosh_death_ts)) -lt 5 ]; then
                death_order_phosh_first=$((death_order_phosh_first + 1))
            fi
        elif [ -n "$phoc_now" ] && [ -z "$phoc_last" ]; then
            phoc_births=$((phoc_births + 1))
        elif [ -n "$phoc_now" ] && [ -n "$phoc_last" ]; then
            phoc_restarts=$((phoc_restarts + 1))
        fi
        phoc_last="$phoc_now"
    fi

    if [ "$phosh_now" != "$phosh_last" ]; then
        emit_transition "phosh" "$phosh_last" "$phosh_now"
        if [ -z "$phosh_now" ] && [ -n "$phosh_last" ]; then
            phosh_deaths=$((phosh_deaths + 1))
            last_phosh_death_ts="$(date +%s)"
            if [ -n "$last_phoc_death_ts" ] && \
               [ $((last_phosh_death_ts - last_phoc_death_ts)) -ge 0 ] && \
               [ $((last_phosh_death_ts - last_phoc_death_ts)) -lt 5 ]; then
                death_order_phoc_first=$((death_order_phoc_first + 1))
            fi
        elif [ -n "$phosh_now" ] && [ -z "$phosh_last" ]; then
            phosh_births=$((phosh_births + 1))
        elif [ -n "$phosh_now" ] && [ -n "$phosh_last" ]; then
            phosh_restarts=$((phosh_restarts + 1))
        fi
        phosh_last="$phosh_now"
    fi

    if [ "$gs_now" != "$gs_last" ]; then
        emit_transition "gnome-session" "$gs_last" "$gs_now"
        [ -n "$gs_last" ] && gs_restarts=$((gs_restarts + 1))
        gs_last="$gs_now"
    fi

    if [ "$greetd_now" != "$greetd_last" ]; then
        emit_transition "greetd" "$greetd_last" "$greetd_now"
        [ -n "$greetd_last" ] && greetd_restarts=$((greetd_restarts + 1))
        greetd_last="$greetd_now"
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done

header "Cycle summary"
info "phoc births"        "$phoc_births"
info "phoc deaths"        "$phoc_deaths"
info "phoc restarts"      "$phoc_restarts (pid changed without going to zero)"
info "phosh births"       "$phosh_births"
info "phosh deaths"       "$phosh_deaths"
info "phosh restarts"     "$phosh_restarts"
info "gnome-session"      "$gs_restarts restarts"
info "greetd"             "$greetd_restarts restarts"

if [ "$phoc_births" -gt "$phosh_births" ]; then cycles="$phoc_births"; else cycles="$phosh_births"; fi
if [ "$cycles" -ge 2 ]; then
    period=$((OBSERVE_SECONDS / cycles))
    info "estimated cycle period" "~${period}s (${cycles} cycles in ${OBSERVE_SECONDS}s)"
elif [ "$cycles" -eq 1 ]; then
    info "estimated cycle period" "single cycle in ${OBSERVE_SECONDS}s — extend ATOMOS_DIAG_OBSERVE_SECONDS"
else
    info "estimated cycle period" "no full cycle in ${OBSERVE_SECONDS}s — symptom may have stopped"
fi

header "Journal excerpt since baseline"
atomos_dump_session_journal_snippet "$TS_BEGIN"

if [ -r /var/log/messages ]; then
    header "/var/log/messages (last 200 lines, filtered)"
    tail -n 200 /var/log/messages 2>/dev/null \
        | grep -Ei 'phoc|phosh|gnome-session|greetd|atomos-app-handler|segfault|signal|exited|virtio_gpu|drm' \
        | tail -n 40 || info "messages" "no matching lines"
fi

header "dmesg markers"
if command -v dmesg >/dev/null 2>&1; then
    _dmesg_needles='virtio_gpu|segfault|signal 11|SIGSEGV|gpu.*reset|drm:.*fault|msm_gpu|etnaviv.*hang|adreno|oom-killer|Out of memory'
    _hit="$(dmesg 2>/dev/null | tail -n 400 | grep -Ei "$_dmesg_needles" | tail -n 30 || true)"
    if [ -n "$_hit" ]; then
        warn "dmesg" "GPU/segfault/OOM markers in last 400 lines (see below)"
        printf '%s\n' "$_hit"
    else
        pass "dmesg" "no GPU/segfault/OOM markers in last 400 lines"
    fi
else
    info "dmesg" "not available"
fi

header "Recent coredumps"
if command -v coredumpctl >/dev/null 2>&1; then
    _cd="$(coredumpctl list --no-pager --since "$TS_BEGIN" 2>/dev/null | tail -n 20 || true)"
    if [ -n "$_cd" ]; then
        printf '%s\n' "$_cd"
    else
        info "coredumpctl" "empty since baseline"
    fi
else
    info "coredumpctl" "not installed"
fi
for _d in /var/crash /var/lib/systemd/coredump; do
    [ -d "$_d" ] || continue
    _newer="$(find "$_d" -newer /tmp/.atomos-diag-anchor 2>/dev/null || true)"
    if [ -n "$_newer" ]; then
        info "new files in $_d"
        printf '%s\n' "$_newer"
    fi
done

header "greetd config + service status"
for _f in /etc/greetd/config.toml /etc/phrog/greetd-config.toml; do
    if [ -f "$_f" ]; then
        info "$_f"
        grep -E '^[a-z_]+|^\[' "$_f" 2>/dev/null | head -n 30 || true
    fi
done
if command -v rc-service >/dev/null 2>&1; then
    _rc="$(rc-service greetd status 2>&1 | head -n 5 | tr '\n' '|' | head -c 300)"
    info "rc-service greetd" "$_rc"
elif command -v systemctl >/dev/null 2>&1; then
    _sd="$(systemctl status greetd --no-pager 2>&1 | head -n 12 | tr '\n' '|' | head -c 400)"
    info "systemctl greetd" "$_sd"
fi

header "Verdict"
# First check: did /var/log/messages capture the gnome-session "killed by
# signal" line for the Phosh shell? That's the unambiguous reproducer of
# the post-login cycle and supersedes the heuristic ordering below.
_phosh_sigsegv=""
if [ -r /var/log/messages ]; then
    _phosh_sigsegv="$(grep -E "Application 'mobi\\.phosh\\.Shell\\.desktop' killed by signal|Unrecoverable failure in required component mobi\\.phosh\\.Shell\\.desktop" /var/log/messages 2>/dev/null | tail -n 4)"
fi
if [ -n "$_phosh_sigsegv" ]; then
    warn "verdict" "Phosh shell SIGSEGV at startup — gnome-session reaped it as 'Unrecoverable failure'"
    info "evidence"
    printf '%s\n' "$_phosh_sigsegv" | sed 's/^/    /'
    info "next step" "run scripts/app-handler/bisect-phosh-runtime-knobs.sh to split runtime-gated vs always-on phosh patches"
    info "also useful" "capture a core: edit /proc/sys/kernel/core_pattern then rerun greetd; gdb /usr/libexec/phosh <core>"
elif [ "$phoc_births" -eq 0 ] && [ "$phosh_births" -eq 0 ] && [ "$greetd_restarts" -eq 0 ]; then
    warn "verdict" "no restarts observed during the window — symptom may have stopped or window too short"
elif [ "$death_order_phoc_first" -gt "$death_order_phosh_first" ]; then
    warn "verdict" "phoc died first in $death_order_phoc_first cycle(s) — start with phoc segfault / wlroots / virtio_gpu"
elif [ "$death_order_phosh_first" -gt "$death_order_phoc_first" ]; then
    warn "verdict" "phosh died first in $death_order_phosh_first cycle(s) — start with phosh shell (atomos-phosh-home-dbus, overview force-hide, app-grid spawn)"
elif [ "$gs_restarts" -gt 0 ] && [ "$phoc_restarts" -eq 0 ]; then
    warn "verdict" "gnome-session is exiting but phoc stays up — likely a session unit dying (atomos-app-handler autostart? sm.puri.phosh service?)"
else
    warn "verdict" "races too tight to attribute at ${POLL_INTERVAL}s polling — rerun with ATOMOS_DIAG_POLL_INTERVAL=0.25 ATOMOS_DIAG_OBSERVE_SECONDS=60"
fi
REMOTE_SH
)

# Splice the runtime library in where the placeholder sits. Use a temp
# file so awk + printf don't have to handle library content quoting.
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

echo "diagnose-session-restart-loop: $SSH_TARGET (port $SSH_PORT) for ${OBSERVE_SECONDS}s"
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<EOF
${REMOTE_PROLOGUE}
${REMOTE_BODY_INLINED}
EOF
