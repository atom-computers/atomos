//! Phosh `home.c` source-level contract tests for chat-ui lifecycle
//! and home-bg layer sync. The app-handler switcher overlay lifecycle
//! (atomos_phosh_sync_app_handler_lifecycle) has been removed — swipe-up
//! now closes the foreground app directly without an overlay.

use std::path::PathBuf;

fn home_c_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../phosh/phosh/src/home.c")
}

fn read_home_c() -> String {
    std::fs::read_to_string(home_c_path()).unwrap_or_else(|e| {
        panic!("read {}: {e}", home_c_path().display())
    })
}

fn strip_c_block_comments(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            while let Some(ch) = chars.next() {
                if ch == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    break;
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

fn extract_function_body(src: &str, name: &str) -> String {
    let needles = [format!("{name} ("), format!("{name}(")];
    let mut hits = Vec::new();
    for needle in &needles {
        let mut from = 0usize;
        while let Some(rel) = src[from..].find(needle.as_str()) {
            let pos = from + rel;
            hits.push(pos);
            from = pos + needle.len();
        }
    }
    hits.sort_unstable();
    hits.dedup();

    for start in hits {
        let brace_start = src[start..]
            .find('{')
            .map(|i| start + i)
            .unwrap_or_else(|| panic!("function {name} opening brace not found"));
        let between = strip_c_block_comments(&src[start..brace_start]);
        if between.contains(';') {
            continue;
        }
        let mut depth = 0usize;
        for (idx, ch) in src[brace_start..].char_indices() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return src[brace_start..=brace_start + idx].to_string();
                    }
                }
                _ => {}
            }
        }
        panic!("unbalanced braces in {name}");
    }
    panic!("function {name} definition not found");
}

#[test]
fn phosh_home_c_lifecycle_delegate_unfolded_sends_overlay() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("ATOMOS_LIFECYCLE_DRAG_STATE"),
        "delegate sends drag state so daemon can compute overlay layer for unfolded"
    );
    let src = read_home_c();
    assert!(
        !src.contains("layer = \"top\"") && !src.contains("layer = \"top\";"),
        "home.c must not set layer=top anywhere — that leaves chat-ui under phosh-home"
    );
}

#[test]
fn phosh_home_c_lifecycle_delegate_covers_home_bg() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("ATOMOS_LIFECYCLE_DRAG_STATE"),
        "delegate sends drag state so daemon can compute home-bg layer (background when folded)"
    );
}

#[test]
fn phosh_home_c_no_direct_layer_assignments_in_c() {
    let src = read_home_c();
    let delegate = extract_function_body(&src, "atomos_phosh_lifecycle_delegate");
    let stripped = strip_c_block_comments(&delegate);
    assert!(
        !stripped.contains("layer = \"bottom\"") && !stripped.contains("layer = \"overlay\"")
            && !stripped.contains("layer = \"top\"") && !stripped.contains("layer = \"background\""),
        "layer assignment is now computed by atomos-lifecycle, not hardcoded in C"
    );
}

#[test]
fn phosh_home_c_lifecycle_delegate_hides_while_locked() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("phosh_shell_get_locked"),
        "delegate must check session lock so daemon can hide both processes when locked"
    );
}

#[test]
fn phosh_home_c_promotes_chat_ui_on_unfold_stable_gate() {
    let src = read_home_c();
    let body = extract_function_body(&src, "mark_ui_stable_for_popups_timeout");
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "after overview unfold stabilizes, lifecycle delegate must fire (which promotes chat-ui)"
    );
}

#[test]
fn phosh_home_c_subscribes_to_shell_locked_for_chat_ui() {
    let src = read_home_c();
    assert!(
        src.contains("notify::locked")
            && src.contains("on_shell_locked_changed_atomos_chat_ui"),
        "PhoshHome must re-sync chat-ui when the session locks or unlocks"
    );
}

#[test]
fn phosh_home_c_map_idle_resyncs_chat_ui_layer_after_autostart() {
    let src = read_home_c();
    assert!(
        src.contains("atomos_phosh_sync_overview_chat_ui_after_map_idle"),
        "phosh_home_map must idle-sync chat-ui layer so autostart bottom is upgraded when home maps unfolded"
    );
    let body = extract_function_body(&src, "phosh_home_map");
    assert!(
        body.contains("g_idle_add (atomos_phosh_sync_overview_chat_ui_after_map_idle"),
        "phosh_home_map must schedule atomos_phosh_sync_overview_chat_ui_after_map_idle"
    );
}

#[test]
fn phosh_home_c_lock_check_before_delegate() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    let locked = delegate
        .find("phosh_shell_get_locked")
        .expect("locked check");
    let env_locked = delegate
        .find("ATOMOS_LIFECYCLE_LOCKED")
        .expect("env locked var");
    assert!(
        locked < env_locked,
        "delegate must read lock state before setting ATOMOS_LIFECYCLE_LOCKED env var"
    );
}

#[test]
fn phosh_home_c_unlock_delegates_lifecycle_and_schedules_retry() {
    let body = extract_function_body(&read_home_c(), "on_shell_locked_changed_atomos_chat_ui");
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "on unlock, delegate lifecycle so daemon resolves layer from toplevel count"
    );
    assert!(
        body.contains("atomos_phosh_schedule_chat_ui_unlock_sync"),
        "on unlock, schedule retry idles so chat-ui promotes after shell/home settle"
    );
}

#[test]
fn phosh_home_c_promote_idle_delegates_lifecycle() {
    let body = extract_function_body(&read_home_c(), "atomos_phosh_promote_chat_ui_when_unlocked_idle");
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "promote idle must delegate lifecycle so daemon chooses BOTTOM when apps are running, \
         not hardcoded UNFOLDED/OVERLAY"
    );
}

#[test]
fn phosh_home_c_constructed_unlocked_schedules_chat_ui_sync() {
    let body = extract_function_body(&read_home_c(), "phosh_home_constructed");
    assert!(
        body.contains("atomos_phosh_schedule_chat_ui_unlock_sync"),
        "session start without lock must promote chat-ui (missed unlock notify)"
    );
}

#[test]
fn phosh_home_c_map_idle_skips_delegate_while_locked() {
    let body = extract_function_body(
        &read_home_c(),
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
    );
    assert!(
        body.contains("phosh_shell_get_locked (shell)")
            && body.contains("return G_SOURCE_REMOVE"),
        "map idle must not delegate while locked (avoids --hide racing with autostart)"
    );
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "map idle must delegate lifecycle when unlocked"
    );
}

#[test]
fn phosh_home_c_lifecycle_delegate_uses_toplevel_count() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT"),
        "delegate must pass toplevel count so daemon can choose BOTTOM vs OVERLAY"
    );
    let drag_body = extract_function_body(&read_home_c(), "on_drag_state_changed");
    assert!(
        drag_body.contains("atomos_phosh_lifecycle_delegate"),
        "drag handler must delegate lifecycle so daemon resolves layer with toplevel count"
    );
}

#[test]
fn phosh_home_c_constructed_locked_defers_without_direct_spawn() {
    let body = extract_function_body(&read_home_c(), "phosh_home_constructed");
    assert!(
        body.contains("g_timeout_add (250, atomos_phosh_rehide_chat_ui_while_locked_idle"),
        "constructed while locked must defer --hide via delayed idle"
    );
    assert!(
        !body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle (self->state)"),
        "constructed must not directly call the old sync function while locked"
    );
}

#[test]
fn phosh_home_c_drag_handler_delegates_lifecycle() {
    let body = extract_function_body(&read_home_c(), "on_drag_state_changed");
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "drag handler must delegate to atomos-lifecycle (daemon handles TRANSITION no-op)"
    );
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("ATOMOS_LIFECYCLE_DRAG_STATE"),
        "delegate must pass drag state so daemon can skip sync during TRANSITION"
    );
}

#[test]
fn phosh_home_c_map_idle_delegates_lifecycle() {
    let body = extract_function_body(
        &read_home_c(),
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
    );
    assert!(
        body.contains("atomos_phosh_lifecycle_delegate"),
        "map idle must delegate lifecycle so daemon derives layer from drag state + toplevels"
    );
}

#[test]
fn phosh_home_c_delegate_reads_drag_surface_state() {
    let delegate = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        delegate.contains("phosh_drag_surface_get_drag_state"),
        "delegate must read drag surface state so daemon computes correct layer for folded/unfolded"
    );
    assert!(
        delegate.contains("PHOSH_DRAG_SURFACE_STATE_UNFOLDED"),
        "delegate must handle UNFOLDED drag state"
    );
}

#[test]
fn phosh_home_c_no_direct_layer_strings() {
    let src = read_home_c();
    let delegate = extract_function_body(&src, "atomos_phosh_lifecycle_delegate");
    let stripped = strip_c_block_comments(&delegate);
    assert!(
        !stripped.contains("layer = \"top\"") && !stripped.contains("layer = \"top\";"),
        "layer=top leaves chat-ui under phosh-home (both TOP) — now computed by atomos-lifecycle"
    );
}

#[test]
fn phosh_home_c_lifecycle_delegate_is_called_from_all_sync_points() {
    let src = read_home_c();
    // Every handler that used to call atomos_phosh_sync_* directly must now
    // call atomos_phosh_lifecycle_delegate(self).
    let sync_points = [
        "mark_ui_stable_for_popups_timeout",
        "atomos_phosh_promote_chat_ui_when_unlocked_idle",
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
        "on_shell_locked_changed_atomos_chat_ui",
        "on_drag_state_changed",
    ];
    for name in &sync_points {
        let body = extract_function_body(&src, name);
        assert!(
            body.contains("atomos_phosh_lifecycle_delegate"),
            "{name} must call atomos_phosh_lifecycle_delegate to delegate lifecycle decisions"
        );
    }
}

#[test]
fn phosh_home_c_lifecycle_delegate_reads_state_from_home_and_shell() {
    let body = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        body.contains("ATOMOS_LIFECYCLE_DRAG_STATE"),
        "delegate must set ATOMOS_LIFECYCLE_DRAG_STATE so the daemon knows home drag state"
    );
    assert!(
        body.contains("ATOMOS_LIFECYCLE_LOCKED"),
        "delegate must set ATOMOS_LIFECYCLE_LOCKED so the daemon knows lock state"
    );
    assert!(
        body.contains("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT"),
        "delegate must set ATOMOS_LIFECYCLE_TOPLEVEL_COUNT so the daemon knows toplevel count"
    );
    assert!(
        body.contains("ATOMOS_LIFECYCLE_PATH"),
        "delegate must reference the atomos-lifecycle binary path"
    );
    assert!(
        body.contains("g_spawn_async"),
        "delegate must use g_spawn_async to invoke the lifecycle binary"
    );
}

#[test]
fn phosh_home_c_lifecycle_delegate_falls_back_when_binary_missing() {
    let body = extract_function_body(&read_home_c(), "atomos_phosh_lifecycle_delegate");
    assert!(
        body.contains("g_file_test") && body.contains("G_FILE_TEST_IS_EXECUTABLE"),
        "delegate must check that atomos-lifecycle exists before spawning; fallback path for old images"
    );
}

#[test]
fn phosh_home_c_map_idle_is_declared_before_phosh_home_map() {
    let src = read_home_c();
    let map_pos = src
        .find("phosh_home_map (GtkWidget *widget)")
        .expect("phosh_home_map");
    let forward = src
        .find("atomos_phosh_sync_overview_chat_ui_after_map_idle (gpointer user_data);")
        .expect("forward decl");
    assert!(
        forward < map_pos,
        "C requires forward declaration before phosh_home_map calls g_idle_add"
    );
}
