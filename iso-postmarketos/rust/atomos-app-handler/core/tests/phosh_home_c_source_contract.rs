//! Phosh `home.c` must implement the same shell lifecycle argv policy as
//! [`atomos_app_handler::shell_lifecycle_argv`]. Rust unit tests alone cannot
//! catch Phosh C regressions (e.g. `--show` on `PHOSH_HOME_STATE_UNFOLDED`).

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

fn extract_switch_case(function_body: &str, case_label: &str) -> String {
    let needle = format!("case {case_label}:");
    let start = function_body
        .find(&needle)
        .unwrap_or_else(|| panic!("missing switch case {case_label} in lifecycle function"));
    let rest = &function_body[start + needle.len()..];
    let end = rest
        .find("case ")
        .or_else(|| rest.find("default:"))
        .unwrap_or(rest.len());
    strip_c_block_comments(&rest[..end])
}

#[test]
fn phosh_home_c_unfolded_must_not_assign_show_or_any_action() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let unfolded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_UNFOLDED");
    assert!(
        !unfolded.contains("action = \"--show\"") && !unfolded.contains("action = \"--show\";"),
        "UNFOLDED must not assign action=\"--show\" (post-unlock black overlay bug)"
    );
    assert!(
        !unfolded.contains("action ="),
        "UNFOLDED must not assign action; only FOLDED may spawn --hide"
    );
}

#[test]
fn phosh_home_c_folded_only_hides_switcher() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let folded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_FOLDED");
    assert!(
        folded.contains("action = \"--hide\"") || folded.contains("action = \"--hide\";"),
        "FOLDED must spawn --hide"
    );
    assert!(!folded.contains("--show"), "FOLDED must not use --show");
}

#[test]
fn phosh_home_c_unfolded_spawns_chat_ui_on_overlay_layer_not_top() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_overview_chat_ui_lifecycle");
    let unfolded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_UNFOLDED");
    assert!(
        unfolded.contains("layer = \"overlay\"") || unfolded.contains("layer = \"overlay\";"),
        "UNFOLDED must set ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay so chat-ui sits above \
         phosh-home (also a TOP layer-shell surface); layer=top leaves chat-ui invisible"
    );
    assert!(
        !unfolded.contains("layer = \"top\"") && !unfolded.contains("layer = \"top\";"),
        "UNFOLDED must not use layer=top for overview-chat-ui"
    );
}

#[test]
fn phosh_home_c_folded_home_bg_uses_background_layer() {
    let body = extract_function_body(&read_home_c(), "atomos_phosh_sync_home_bg_layer");
    let folded = extract_switch_case(&body, "PHOSH_HOME_STATE_FOLDED");
    assert!(
        folded.contains("layer = \"background\"") || folded.contains("layer = \"background\";"),
        "FOLDED home-bg must use background layer (below chat-ui on bottom/overlay)"
    );
}

#[test]
fn phosh_home_c_folded_spawns_chat_ui_on_bottom_layer() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_overview_chat_ui_lifecycle");
    let folded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_FOLDED");
    assert!(
        folded.contains("layer = \"bottom\"") || folded.contains("layer = \"bottom\";"),
        "FOLDED must set layer=bottom"
    );
}

#[test]
fn phosh_home_c_chat_ui_lifecycle_hides_while_session_locked() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_overview_chat_ui_lifecycle");
    assert!(
        lifecycle_fn.contains("phosh_shell_get_locked"),
        "overview-chat-ui lifecycle must check session lock before overlay --show"
    );
    assert!(
        lifecycle_fn.contains("--hide"),
        "overview-chat-ui lifecycle must hide while locked (overlay paints above lock surface)"
    );
}

#[test]
fn phosh_home_c_promotes_chat_ui_on_unfold_stable_gate() {
    let src = read_home_c();
    let body = extract_function_body(&src, "mark_ui_stable_for_popups_timeout");
    assert!(
        body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle")
            && body.contains("PHOSH_HOME_STATE_UNFOLDED"),
        "after overview unfold stabilizes, chat-ui must be promoted to overlay"
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
fn phosh_home_c_chat_ui_lock_check_runs_before_layer_switch() {
    let lifecycle_fn =
        extract_function_body(&read_home_c(), "atomos_phosh_sync_overview_chat_ui_lifecycle");
    let locked = lifecycle_fn
        .find("phosh_shell_get_locked")
        .expect("locked check");
    let layer_switch = lifecycle_fn
        .find("switch (state)")
        .expect("state switch");
    assert!(
        locked < layer_switch,
        "must --hide while locked before choosing overlay/bottom layer"
    );
}

#[test]
fn phosh_home_c_unlock_promotes_overlay_and_schedules_retry() {
    let body = extract_function_body(&read_home_c(), "on_shell_locked_changed_atomos_chat_ui");
    assert!(
        body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle (PHOSH_HOME_STATE_UNFOLDED)")
            && body.contains("atomos_phosh_schedule_chat_ui_unlock_sync"),
        "on unlock, run overlay --show immediately then schedule retries"
    );
    let schedule = extract_function_body(&read_home_c(), "atomos_phosh_schedule_chat_ui_unlock_sync");
    assert!(
        schedule.contains("atomos_phosh_promote_chat_ui_when_unlocked_idle"),
        "unlock sync must promote overlay above phosh-home"
    );
    assert!(
        schedule.contains("g_timeout_add (500"),
        "unlock sync must retry after shell/home finish starting"
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
fn phosh_home_c_map_idle_skips_hide_while_locked() {
    let body = extract_function_body(
        &read_home_c(),
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
    );
    assert!(
        body.contains("phosh_shell_get_locked (shell)")
            && body.contains("return G_SOURCE_REMOVE")
            && !body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle (PHOSH_HOME_STATE_FOLDED)"),
        "map idle must not --hide while locked (autostart race on 2nd boot)"
    );
    assert!(
        body.contains("atomos_phosh_chat_ui_layer_state_for_home"),
        "map idle must use layer helper when unlocked"
    );
}

#[test]
fn phosh_home_c_chat_ui_layer_helper_uses_toplevel_count() {
    let src = read_home_c();
    assert!(
        src.contains("atomos_phosh_chat_ui_layer_state_for_home")
            && src.contains("phosh_toplevel_manager_get_num_toplevels"),
        "folded home without apps must promote chat-ui to overlay"
    );
    let body = extract_function_body(&src, "on_drag_state_changed");
    assert!(
        body.contains("atomos_phosh_chat_ui_layer_state_for_home"),
        "drag handler must use layer helper (no bottom under phosh-home after unlock)"
    );
}

#[test]
fn phosh_home_c_constructed_locked_defers_hide_without_immediate_sync() {
    let body = extract_function_body(&read_home_c(), "phosh_home_constructed");
    assert!(
        body.contains("g_timeout_add (250, atomos_phosh_rehide_chat_ui_while_locked_idle")
            && !body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle (self->state)"),
        "constructed while locked must not immediately --hide autostart chat-ui"
    );
}

#[test]
fn phosh_home_c_drag_transition_does_not_sync_chat_ui() {
    let body = extract_function_body(&read_home_c(), "on_drag_state_changed");
    assert!(
        body.contains("if (self->state != PHOSH_HOME_STATE_TRANSITION)")
            && body.contains("atomos_phosh_sync_overview_chat_ui_lifecycle"),
        "during DRAGGED/TRANSITION, skip chat-ui sync until unfold settles"
    );
}

#[test]
fn phosh_home_c_map_idle_derives_state_from_drag_surface() {
    let body = extract_function_body(
        &read_home_c(),
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
    );
    assert!(
        body.contains("atomos_phosh_chat_ui_layer_state_for_home"),
        "map idle must derive layer from drag + toplevels, not stale self->state"
    );
}

#[test]
fn phosh_home_c_chat_ui_state_helper_reads_drag_surface() {
    let body = extract_function_body(&read_home_c(), "atomos_phosh_chat_ui_state_from_home");
    assert!(
        body.contains("phosh_drag_surface_get_drag_state"),
        "effective chat-ui fold state follows drag surface"
    );
    assert!(
        body.contains("PHOSH_DRAG_SURFACE_STATE_UNFOLDED"),
        "unfolded drag maps to UNFOLDED home state for overlay promotion"
    );
}

#[test]
fn phosh_home_c_never_uses_top_layer_for_chat_ui() {
    let lifecycle_fn =
        extract_function_body(&read_home_c(), "atomos_phosh_sync_overview_chat_ui_lifecycle");
    let stripped = strip_c_block_comments(&lifecycle_fn);
    assert!(
        !stripped.contains("layer = \"top\"") && !stripped.contains("layer = \"top\";"),
        "layer=top leaves chat-ui under phosh-home (both TOP)"
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

#[test]
fn phosh_home_c_lifecycle_function_never_spawns_show() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let tail = strip_c_block_comments(&lifecycle_fn);
    assert!(
        !tail.contains("action = \"--show\"") && !tail.contains("action = \"--show\";"),
        "lifecycle sync must not spawn --show"
    );
}
