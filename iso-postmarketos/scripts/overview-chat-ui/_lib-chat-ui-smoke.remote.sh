# Remote-only helpers for overview-chat-ui runtime smoke (POSIX sh).
# Inlined by smoke-chat-ui-post-unlock.sh — not for direct execution on the host.
#
# Requires: pass/warn/info/header, atomos_detect_graphical_runtime,
# atomos_session_busctl, atomos_find_phosh_pid (from _lib-post-unlock-runtime-checks.remote.sh).

atomos_find_chat_ui_binary_pid() {
    pgrep -f '/usr/local/bin/atomos-overview-chat-ui' 2>/dev/null | head -n1 || true
}

atomos_chat_ui_log_path() {
    if [ -n "${ATOMOS_SESSION_RUN:-}" ] && [ -f "${ATOMOS_SESSION_RUN}/atomos-overview-chat-ui.log" ]; then
        echo "${ATOMOS_SESSION_RUN}/atomos-overview-chat-ui.log"
        return 0
    fi
    for _f in /run/user/*/atomos-overview-chat-ui.log; do
        if [ -f "$_f" ]; then
            echo "$_f"
            return 0
        fi
    done
    echo ""
}

atomos_chat_ui_layer_from_environ() {
    _pid="$1"
    [ -n "$_pid" ] && [ -r "/proc/$_pid/environ" ] || return 1
    tr '\000' '\n' < "/proc/$_pid/environ" 2>/dev/null \
        | awk -F= '/^ATOMOS_OVERVIEW_CHAT_UI_LAYER=/ { print $2; exit }'
}

atomos_chat_ui_smoke_drive_unfold_and_assert_overlay() {
    _settle="${ATOMOS_CHAT_UI_SMOKE_SETTLE_SEC:-4}"

    header "Chat-UI runtime: D-Bus fold then unfold (drives Phosh lifecycle)"
    if ! command -v busctl >/dev/null 2>&1; then
        warn "busctl" "not installed — cannot drive SetUnfolded for runtime layer check"
        return 1
    fi
    atomos_detect_graphical_runtime || true
    if ! atomos_session_busctl status org.atomos.PhoshHome >/dev/null 2>&1; then
        warn "org.atomos.PhoshHome D-Bus" "missing on session bus — rebuild phosh with AtomOS home D-Bus"
        return 1
    fi
    pass "org.atomos.PhoshHome D-Bus" "present on session bus"

    if ! atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome SetFolded >/dev/null 2>&1; then
        warn "SetFolded" "D-Bus call failed"
        return 1
    fi
    pass "SetFolded" "ok"
    sleep 1

    _log="$(atomos_chat_ui_log_path)"
    _pid="$(atomos_find_chat_ui_binary_pid)"
    if [ -n "$_pid" ]; then
        _fold_layer="$(atomos_chat_ui_layer_from_environ "$_pid" || true)"
        info "after SetFolded" "chat-ui pid=$_pid ATOMOS_OVERVIEW_CHAT_UI_LAYER=${_fold_layer:-<unset>}"
    fi

    if ! atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome SetUnfolded >/dev/null 2>&1; then
        warn "SetUnfolded" "D-Bus call failed"
        return 1
    fi
    pass "SetUnfolded" "ok"
    info "settling" "${_settle}s for mark_ui_stable + async launcher (ATOMOS_CHAT_UI_SMOKE_SETTLE_SEC)"
    sleep "$_settle"

    _state="$(atomos_session_busctl call org.atomos.PhoshHome /org/atomos/PhoshHome org.atomos.PhoshHome GetState 2>/dev/null | awk '{print $2}' | tr -d '"' || true)"
    if [ "$_state" = "unfolded" ]; then
        pass "GetState after SetUnfolded" "unfolded"
    else
        warn "GetState after SetUnfolded" "expected unfolded, got ${_state:-<empty>}"
    fi

    header "Chat-UI runtime: layer and log after unfold"
    _pid="$(atomos_find_chat_ui_binary_pid)"
    if [ -z "$_pid" ]; then
        warn "chat-ui binary running" "no /usr/local/bin/atomos-overview-chat-ui process after SetUnfolded"
        return 1
    fi
    pass "chat-ui binary running" "pid=$_pid"

    _layer="$(atomos_chat_ui_layer_from_environ "$_pid" || true)"
    if [ "$_layer" = "overlay" ]; then
        pass "chat-ui process layer env" "ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay"
    else
        warn "chat-ui process layer env" "got ATOMOS_OVERVIEW_CHAT_UI_LAYER=${_layer:-<unset>} — need overlay above phosh-home (TOP); invisible on unfolded home if bottom"
        return 1
    fi

    _log="$(atomos_chat_ui_log_path)"
    if [ -z "$_log" ]; then
        warn "chat-ui launcher log" "no atomos-overview-chat-ui.log under /run/user/*"
        return 1
    fi
    info "chat-ui log path" "$_log"

    if grep -qE 'action=show.*layer=overlay|ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay|gtk_layer=Overlay' "$_log" 2>/dev/null; then
        pass "chat-ui log shows overlay promotion" "found overlay layer marker in log"
    else
        warn "chat-ui log shows overlay promotion" "no action=show layer=overlay / gtk_layer=Overlay in log — Phosh lifecycle may not have run --show"
        tail -n 20 "$_log" 2>/dev/null || true
        return 1
    fi

    if grep -q 'action=show.*layer=bottom' "$_log" 2>/dev/null && ! grep -q 'layer=overlay' "$_log" 2>/dev/null; then
        warn "chat-ui log layer history" "only bottom --show in log; overlay promotion never ran"
        return 1
    fi

    return 0
}
