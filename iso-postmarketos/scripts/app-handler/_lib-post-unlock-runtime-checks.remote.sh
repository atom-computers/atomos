# Remote-only helpers (POSIX sh). Inlined into diagnose-app-handler.sh and
# smoke-post-unlock.sh — not for direct execution on the host.
#
# Catches runtime failures static/unit tests cannot see:
#   - phoc Wayland/protocol "permission denied" after lockscreen unlock
#   - phosh/phoc restart or crash during the unlock window
#   - compositor missing layer-shell globals for the session user

# Usage on device (after defining pass/warn/info/header):
#   atomos_smoke_wait_for_phosh_session   # unlock on device first
#   TS_BEGIN="$(date -Iseconds 2>/dev/null || date)"
#   atomos_post_unlock_capture_baseline
#   atomos_post_unlock_check_phoc_journal_since "$TS_BEGIN"

atomos_find_phosh_pid() {
    _pid="$(pgrep -x phosh 2>/dev/null | head -n1 || true)"
    [ -n "$_pid" ] && { echo "$_pid"; return 0; }
    _pid="$(pgrep -x phosh.real 2>/dev/null | head -n1 || true)"
    [ -n "$_pid" ] && { echo "$_pid"; return 0; }
    for _pid in $(pgrep -f phosh 2>/dev/null); do
        _args="$(ps -o args= -p "$_pid" 2>/dev/null || true)"
        case "$_args" in
            *libexec/phosh* | */usr/libexec/phosh* )
                echo "$_pid"
                return 0
                ;;
        esac
    done
    _pid="$(ps 2>/dev/null | awk '/libexec\/phosh|\/usr\/libexec\/phosh/{print $1; exit}')"
    [ -n "$_pid" ] && { echo "$_pid"; return 0; }
    echo ""
}

atomos_find_phoc_pid() {
    pgrep -x phoc 2>/dev/null | head -n1 || true
}

atomos_find_gnome_session_phosh_pid() {
    pgrep -f gnome-session 2>/dev/null | head -n1 || true
}

atomos_find_handler_pids() {
    pgrep -f '/usr/local/bin/atomos-app-handler|atomos-app-handler --' 2>/dev/null | tr '\n' ' ' || true
}

atomos_detect_graphical_runtime() {
    ATOMOS_SESSION_UID=""
    ATOMOS_SESSION_RUN=""
    ATOMOS_SESSION_DBUS=""
    ATOMOS_SESSION_WL_DISPLAY="wayland-0"

    _phosh_pid="$(atomos_find_phosh_pid)"
    if [ -n "$_phosh_pid" ] && [ -r "/proc/$_phosh_pid/environ" ]; then
        ATOMOS_SESSION_RUN="$(tr '\000' '\n' < "/proc/$_phosh_pid/environ" | awk -F= '/^XDG_RUNTIME_DIR=/ {print $2; exit}')"
        ATOMOS_SESSION_WL_DISPLAY="$(tr '\000' '\n' < "/proc/$_phosh_pid/environ" | awk -F= '/^WAYLAND_DISPLAY=/ {print $2; exit}')"
        ATOMOS_SESSION_WL_DISPLAY="${ATOMOS_SESSION_WL_DISPLAY:-wayland-0}"
        if [ -n "$ATOMOS_SESSION_RUN" ]; then
            ATOMOS_SESSION_UID="${ATOMOS_SESSION_RUN##*/}"
            if [ -S "$ATOMOS_SESSION_RUN/bus" ]; then
                ATOMOS_SESSION_DBUS="unix:path=$ATOMOS_SESSION_RUN/bus"
            fi
            return 0
        fi
    fi

    for _d in /run/user/*; do
        [ -d "$_d" ] || continue
        _uid="${_d##*/}"
        case "$_uid" in *[!0-9]*) continue ;; esac
        if [ -S "$_d/wayland-0" ] || [ -S "$_d/wayland-1" ]; then
            ATOMOS_SESSION_RUN="$_d"
            ATOMOS_SESSION_UID="$_uid"
            if [ -S "$_d/wayland-1" ]; then
                ATOMOS_SESSION_WL_DISPLAY="wayland-1"
            else
                ATOMOS_SESSION_WL_DISPLAY="wayland-0"
            fi
            if [ -S "$_d/bus" ]; then
                ATOMOS_SESSION_DBUS="unix:path=$_d/bus"
            fi
            return 0
        fi
    done
    return 1
}

atomos_session_busctl() {
    if [ -n "${ATOMOS_SESSION_DBUS:-}" ]; then
        DBUS_SESSION_BUS_ADDRESS="$ATOMOS_SESSION_DBUS" \
        XDG_RUNTIME_DIR="${ATOMOS_SESSION_RUN:-}" \
            busctl --user "$@"
    else
        busctl --user "$@"
    fi
}

atomos_dump_session_journal_snippet() {
    _since="${1:-}"
    header "Journal excerpt (phosh/phoc/gnome-session/permission denied)"
    if ! command -v journalctl >/dev/null 2>&1; then
        info "journalctl" "not installed"
        return
    fi
    _jargs="-b --no-pager -n 120"
    if [ -n "$_since" ]; then
        _jargs="-b --no-pager --since $_since"
    fi
    # shellcheck disable=SC2086
    journalctl $_jargs 2>/dev/null \
        | grep -Ei 'phoc|phosh|gnome-session|greetd|atomos-app-handler|permission denied|WL_DISPLAY_ERROR|segfault|fatal|assert|trap|crashed' \
        | tail -n 40 || info "journal" "no matching lines (session may not log to journal)"
}

atomos_diagnose_session_kind() {
    header "Session kind (phrog greeter vs Phosh shell)"
    _ssh_uid="$(id -u 2>/dev/null || echo 0)"
    info "ssh login uid" "$_ssh_uid (graphics may run as a different uid until greetd login completes)"

    if ps -ef 2>/dev/null | grep -q 'gnome-session.*session=phrog'; then
        if ps -ef 2>/dev/null | grep -qE 'gnome-session.*session=phosh|/usr/bin/phosh-session|/usr/libexec/phosh'; then
            pass "session transition" "phrog greeter and phosh shell both visible"
        else
            warn "session kind" "only phrog greeter (session=phrog) — NOT logged into Phosh yet"
            info "next step" "on the device display: enter password for user and confirm login (not just swipe)"
            info "expect after login" "ps shows session=phosh and /usr/libexec/phosh as user uid $_ssh_uid"
        fi
    elif ps -ef 2>/dev/null | grep -qE 'gnome-session.*session=phosh|/usr/libexec/phosh'; then
        pass "session kind" "phosh shell session running"
    else
        warn "session kind" "no phrog or phosh gnome-session detected"
    fi

    if [ -x /usr/share/wayland-sessions/phosh.desktop ]; then
        pass "wayland session file" "/usr/share/wayland-sessions/phosh.desktop"
        grep '^Exec=' /usr/share/wayland-sessions/phosh.desktop 2>/dev/null || true
    else
        warn "wayland session file" "missing phosh.desktop (greetd may not know how to start phosh-session)"
    fi
    if [ -f /etc/phrog/greetd-config.toml ]; then
        info "greetd greeter command" "$(grep '^command' /etc/phrog/greetd-config.toml 2>/dev/null | head -n1)"
    fi
}

atomos_smoke_report_session_hints() {
    header "Session troubleshooting hints"
    if command -v loginctl >/dev/null 2>&1; then
        info "loginctl" "$(loginctl list-sessions --no-legend 2>/dev/null | head -n 5 | tr '\n' '|' || true)"
    fi
    for _d in /run/user/*; do
        [ -d "$_d" ] || continue
        _marks=""
        [ -S "$_d/wayland-0" ] && _marks="${_marks}wayland-0 "
        [ -S "$_d/wayland-1" ] && _marks="${_marks}wayland-1 "
        [ -S "$_d/bus" ] && _marks="${_marks}bus "
        [ -n "$_marks" ] && info "runtime $_d" "$_marks"
    done
    _ps="$(ps -eo pid,comm 2>/dev/null | grep -Ei 'phosh|phoc|greetd' | grep -v grep | head -n 8 | tr '\n' '|' || true)"
    info "ps phosh/phoc/greetd" "${_ps:-<none>}"
}

atomos_smoke_wait_for_phosh_session() {
    _wait="${ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC:-90}"
    _step=3
    _elapsed=0
    _phoc_baseline="$(atomos_find_phoc_pid)"
    _phoc_restarts=0
    header "Wait for Phosh session (unlock on the device display now)"
    info "wait budget" "${_wait}s (set ATOMOS_SMOKE_WAIT_FOR_SESSION_SEC to override)"
    [ -n "$_phoc_baseline" ] && info "phoc baseline" "pid=$_phoc_baseline"
    while [ "$_elapsed" -lt "$_wait" ]; do
        _pid="$(atomos_find_phosh_pid)"
        if [ -n "$_pid" ] && atomos_detect_graphical_runtime; then
            pass "phosh session up" "pid=$_pid uid=${ATOMOS_SESSION_UID:-?} runtime=${ATOMOS_SESSION_RUN:-?}"
            return 0
        fi
        _phoc="$(atomos_find_phoc_pid)"
        if [ -n "$_phoc_baseline" ] && [ -n "$_phoc" ] && [ "$_phoc" != "$_phoc_baseline" ]; then
            _phoc_restarts=$((_phoc_restarts + 1))
            warn "phoc pid changed" "$_phoc_baseline -> $_phoc (compositor restart #$_phoc_restarts — session crash loop?)"
            _phoc_baseline="$_phoc"
        fi
        _gs="$(atomos_find_gnome_session_phosh_pid)"
        if pgrep -f greetd >/dev/null 2>&1; then _greetd=yes; else _greetd=no; fi
        info "waiting ${_elapsed}s" "phosh=${_pid:-<missing>} gnome-session=${_gs:-<missing>} phoc=${_phoc:-<missing>} greetd=${_greetd}"
        sleep "$_step"
        _elapsed=$((_elapsed + _step))
    done
    warn "phosh session" "not running after ${_wait}s"
    if [ "$_phoc_restarts" -gt 0 ]; then
        warn "session stability" "phoc restarted $_phoc_restarts time(s) during wait — UI crash loop after unlock"
    fi
    atomos_smoke_report_session_hints
    atomos_dump_session_journal_snippet "${ATOMOS_BASELINE_TS:-}"
    return 1
}

atomos_post_unlock_capture_baseline() {
    ATOMOS_BASELINE_TS="${ATOMOS_BASELINE_TS:-$(date -Iseconds 2>/dev/null || date)}"
    ATOMOS_BASELINE_PHOC_PID="$(pgrep -x phoc 2>/dev/null | head -n1 || true)"
    ATOMOS_BASELINE_PHOSH_PID="$(atomos_find_phosh_pid)"
}

atomos_proc_start_ticks() {
    _pid="$1"
    [ -n "$_pid" ] || return 1
    awk '{print $22}' "/proc/$_pid/stat" 2>/dev/null || return 1
}

atomos_post_unlock_check_phoc_process_stable() {
    header "Phoc compositor stable after unlock"
    if [ -z "${ATOMOS_BASELINE_PHOC_PID:-}" ]; then
        ATOMOS_BASELINE_PHOC_PID="$(pgrep -x phoc 2>/dev/null | head -n1 || true)"
    fi
    phoc_now="$(pgrep -x phoc 2>/dev/null | head -n1 || true)"
    if [ -z "$phoc_now" ]; then
        warn "phoc running" "compositor pid missing after unlock"
        return
    fi
    pass "phoc running" "pid=$phoc_now"
    if [ -n "${ATOMOS_BASELINE_PHOC_PID:-}" ] && [ "$phoc_now" != "$ATOMOS_BASELINE_PHOC_PID" ]; then
        warn "phoc pid stable" "was $ATOMOS_BASELINE_PHOC_PID now $phoc_now (compositor restarted?)"
    else
        pass "phoc pid stable" "${ATOMOS_BASELINE_PHOC_PID:-unknown} -> $phoc_now"
    fi
}

atomos_post_unlock_check_phoc_journal_since() {
    _since="${1:-}"
    header "Phoc / session journal (permission denied & crash hints since unlock)"
    if ! command -v journalctl >/dev/null 2>&1; then
        warn "journalctl" "not installed; cannot detect phoc permission denied at runtime"
        return
    fi
    _jargs="-b --no-pager"
    if [ -n "$_since" ]; then
        _jargs="$_jargs --since $_since"
    else
        _jargs="$_jargs -n 200"
    fi
    # shellcheck disable=SC2086
    _journal="$(journalctl $_jargs 2>/dev/null || true)"
    if [ -z "$_journal" ]; then
        info "journalctl" "empty or unavailable for user; try: loginctl enable-linger \$USER"
        return
    fi

    _phoc_hits="$(echo "$_journal" | grep -Ei 'phoc|phosh-session|gnome-session|greetd|atomos-app-handler|layer.shell|wayland' || true)"
    _denied="$(echo "$_phoc_hits" | grep -Ei 'permission denied|permission to bind|not allowed|WL_DISPLAY_ERROR|access denied' || true)"
    if [ -n "$_denied" ]; then
        warn "phoc/session permission denied" "see journal excerpt below"
        echo "$_denied" | tail -n 15
    else
        pass "phoc/session permission denied" "none in journal since baseline"
    fi

    _crash="$(echo "$_phoc_hits" | grep -Ei 'segfault|core dump|coredump|fatal|assertion failed|trap|aborted|crashed' || true)"
    if [ -n "$_crash" ]; then
        warn "phoc/session crash hints" "see journal excerpt below"
        echo "$_crash" | tail -n 15
    else
        pass "phoc/session crash hints" "none in journal since baseline"
    fi

    if command -v coredumpctl >/dev/null 2>&1; then
        _cores="$(coredumpctl list --no-pager 2>/dev/null | grep -Ei 'phoc|phosh' | tail -n 5 || true)"
        if [ -n "$_cores" ]; then
            warn "recent phoc/phosh coredumps" "see coredumpctl list"
            echo "$_cores"
        else
            pass "recent phoc/phosh coredumps" "none listed"
        fi
    fi
}

atomos_post_unlock_check_phosh_profile_env_readable() {
    header "phosh-profile.env readable by session (not a write-time Permission denied)"
    _f="/etc/atomos/phosh-profile.env"
    if [ ! -f "$_f" ]; then
        warn "$_f" "missing"
        return
    fi
    if [ -r "$_f" ]; then
        pass "$_f readable"
        if grep -q '^ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1' "$_f" 2>/dev/null \
            && grep -q '^ATOMOS_APP_HANDLER_TAKES_OVER=1' "$_f" 2>/dev/null; then
            pass "phosh-profile keys" "bottom-edge + handler takeover set"
        else
            warn "phosh-profile keys" "expected ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 and ATOMOS_APP_HANDLER_TAKES_OVER=1"
        fi
    else
        warn "$_f readable" "session cannot read env file (check permissions/ownership)"
    fi
}

# Same gate as tests/integration/test_qemu_phosh_login_lifetime.py: assert
# the phosh pid stays alive across a hold window. Catches the post-login
# QEMU virtio-gpu / phoc crash class on real hardware too.
atomos_post_unlock_check_phosh_runtime_hold() {
    _hold="${1:-15}"
    header "Phosh runtime hold (pid alive across ${_hold}s window)"
    _pid="$(atomos_find_phosh_pid)"
    if [ -z "$_pid" ]; then
        warn "phosh pid before hold" "no pid — session may have crashed already"
        return
    fi
    info "phosh pid" "$_pid"
    _step=2
    _waited=0
    while [ "$_waited" -lt "$_hold" ]; do
        sleep "$_step"
        _waited=$((_waited + _step))
        if ! kill -0 "$_pid" 2>/dev/null; then
            warn "phosh runtime hold" "pid $_pid died after ${_waited}s (post-login crash, see dmesg / journal)"
            return
        fi
    done
    pass "phosh runtime hold" "pid $_pid alive after ${_hold}s"
}

# Greps dmesg + /var/log/messages for the crash signatures we saw in
# QEMU's virtio_gpu_simple_process_cmd / -[QemuCocoaView switchSurface:]
# trace, plus the kernel-side equivalents (msm/etnaviv GPU resets etc.).
# Mirror of tests/integration/test_qemu_phosh_login_lifetime.py grep.
atomos_post_unlock_check_gpu_segfault_dmesg() {
    header "dmesg / /var/log/messages: GPU + phosh crash markers"
    _needles='virtio_gpu|phosh.*segfault|phoc.*segfault|gpu.*reset|signal 11|SIGSEGV|drm:.*fault|msm_gpu|etnaviv.*hang|adreno'

    _hits=""
    if command -v dmesg >/dev/null 2>&1; then
        _dmesg_out="$(dmesg 2>/dev/null | grep -Ei "$_needles" | tail -n 30 || true)"
        if [ -n "$_dmesg_out" ]; then
            _hits="dmesg:
$_dmesg_out
"
        fi
    fi
    if [ -r /var/log/messages ]; then
        _msg_out="$(grep -Ei "$_needles" /var/log/messages 2>/dev/null | tail -n 30 || true)"
        if [ -n "$_msg_out" ]; then
            _hits="${_hits}/var/log/messages:
$_msg_out
"
        fi
    fi

    if [ -z "$_hits" ]; then
        pass "dmesg/messages GPU+phosh markers" "none"
    else
        warn "dmesg/messages GPU+phosh markers" "see excerpt below"
        printf '%s' "$_hits" | tail -n 40
    fi
}
