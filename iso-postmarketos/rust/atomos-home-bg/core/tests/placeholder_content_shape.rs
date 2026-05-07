//! Shape-check the placeholder HTML + JS shipped under
//! `data/atomos-home-bg/`.
//!
//! The placeholder is a WebGL black-hole / accretion-disk shader on a
//! `#0a0a0a` base — see `event-horizon.tsx` (canonical React source)
//! and `event-horizon.js` (vanilla port loaded by WebKit at runtime).
//!
//! These tests pin three things:
//!   1. the HTML really does load the shader script and host a canvas
//!      it can attach to;
//!   2. the dark base color is in place so the surface stays opaque
//!      even before WebGL has uploaded the first frame (or if WebGL
//!      fails to initialize on a given device);
//!   3. the React source and the vanilla JS port stay in lock-step on
//!      the things that matter for runtime behavior (shared shader
//!      uniforms, shared parameter defaults, shared message API).

use std::path::PathBuf;

fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .join("data/atomos-home-bg")
}

fn read_data_file(name: &str) -> String {
    let path = data_dir().join(name);
    assert!(
        path.exists(),
        "placeholder asset missing at {}",
        path.display()
    );
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()))
}

fn placeholder_html() -> String {
    read_data_file("index.html")
}

fn event_horizon_js() -> String {
    read_data_file("event-horizon.js")
}

fn event_horizon_tsx() -> String {
    read_data_file("event-horizon.tsx")
}

#[test]
fn placeholder_has_dark_base_color() {
    let html = placeholder_html();
    let has_dark =
        html.contains("background: #0a0a0a") || html.contains("background:#0a0a0a");
    assert!(
        has_dark,
        "placeholder must set the #0a0a0a opaque base color so the surface \
         stays solid before WebGL paints / if WebGL fails"
    );
}

#[test]
fn placeholder_loads_event_horizon_script_and_hosts_canvas() {
    let html = placeholder_html();
    assert!(
        html.contains("<canvas") && html.contains("id=\"event-horizon\""),
        "placeholder must host a <canvas id=\"event-horizon\"> for the shader to attach to"
    );
    assert!(
        html.contains("src=\"event-horizon.js\""),
        "placeholder must load the sibling event-horizon.js (the vanilla port \
         the install script ships next to index.html)"
    );
}

#[test]
fn placeholder_carries_atomos_home_bg_marker() {
    let html = placeholder_html();
    // build-qemu's verify_rootfs step greps the installed file to confirm
    // it really is the atomos-home-bg payload (and not e.g. an empty file
    // or some other project's index.html). Keep the marker stable.
    assert!(
        html.contains("atomos-home-bg placeholder"),
        "placeholder must carry an `atomos-home-bg placeholder` marker so build-qemu verify_rootfs can identify it"
    );
}

#[test]
fn placeholder_html_and_body_are_full_viewport() {
    let html = placeholder_html();
    // If html/body don't fill the viewport, the canvas collapses to a
    // strip and the underlying compositor color shows through.
    assert!(html.contains("html,") && html.contains("body"));
    assert!(html.contains("width: 100%"));
    assert!(html.contains("height: 100%"));
    assert!(
        html.contains("margin: 0"),
        "placeholder must zero default body margin so the dark surface reaches every edge"
    );
}

#[test]
fn placeholder_is_self_contained_no_external_assets() {
    let html = placeholder_html();
    let forbidden = [
        "src=\"http://",
        "src=\"https://",
        "src='http://",
        "src='https://",
        "href=\"http://",
        "href=\"https://",
    ];
    for needle in forbidden {
        assert!(
            !html.contains(needle),
            "placeholder references a remote asset ({needle}); must stay self-contained"
        );
    }
}

#[test]
fn event_horizon_js_uses_webgl_and_attaches_to_named_canvas() {
    let js = event_horizon_js();
    assert!(
        js.contains("getContext(\"webgl\"")
            || js.contains("getContext('webgl'"),
        "event-horizon.js must request a WebGL context"
    );
    assert!(
        js.contains("getElementById(\"event-horizon\")"),
        "event-horizon.js must attach to the <canvas id=\"event-horizon\"> the HTML provides"
    );
    assert!(
        js.contains("requestAnimationFrame"),
        "event-horizon.js must drive the animation via requestAnimationFrame"
    );
}

#[test]
fn event_horizon_js_is_resilient_to_missing_webgl() {
    let js = event_horizon_js();
    // The home-bg surface must never crash the webview — if WebGL is
    // unavailable on a given device, the script must bail cleanly so
    // the dark CSS base stays painted.
    assert!(
        js.contains("if (!gl)"),
        "event-horizon.js must check the WebGL context before using it; \
         a null context must short-circuit init, not throw"
    );
}

#[test]
fn event_horizon_js_emits_visible_diagnostics_on_failure() {
    let js = event_horizon_js();
    // On-device the user has no easy way to tell apart "JS didn't load"
    // from "WebGL refused" from "shader failed to compile" — every one
    // looks like the dark CSS base. The diagnostic banner makes the
    // failure mode visible without an SSH log dive.
    assert!(
        js.contains("event-horizon-diag"),
        "event-horizon.js must emit a diagnostic DOM element so on-device \
         failures are visible without log access"
    );
    assert!(
        js.contains("function reportFailure"),
        "event-horizon.js must define a reportFailure() helper so every \
         failure path can fan out to both console and the diag banner"
    );
    // Each canonical failure path the script can hit — protect them
    // individually so a refactor that drops one is caught by tests.
    for stage in [
        "canvas missing",
        "WebGL context creation threw",
        "WebGL unavailable",
        "shader compile failed",
        "program create failed",
        "program link error",
    ] {
        assert!(
            js.contains(stage),
            "event-horizon.js must report the `{stage}` failure stage to the diag banner"
        );
    }
    // Diagnostics suppression hatch for production wallpaper use.
    assert!(
        js.contains("?diag=0") || js.contains("diag=0"),
        "event-horizon.js must support a `?diag=0` URL toggle to hide the \
         diagnostic banner once the device is known healthy"
    );
}

#[test]
fn event_horizon_js_signals_first_frame_to_clear_stale_banner() {
    let js = event_horizon_js();
    assert!(
        js.contains("firstFramePainted"),
        "event-horizon.js must remove the diagnostic banner once the first \
         GL frame is painted, so a transient WebGL hiccup doesn't leave \
         a stale 'WebGL unavailable' banner on a healthy device"
    );
}

#[test]
fn event_horizon_js_caps_dpr_to_protect_phone_gpus() {
    let js = event_horizon_js();
    // The 200-iteration ray-march in the fragment shader is heavy; we
    // intentionally cap devicePixelRatio at 1.5 so a 3x phone display
    // doesn't quadruple the per-frame fragment cost. Pin the cap.
    assert!(
        js.contains("Math.min(window.devicePixelRatio || 1, 1.5)"),
        "event-horizon.js must cap DPR at 1.5 to keep the ray-march tractable on phone GPUs"
    );
}

#[test]
fn event_horizon_js_exposes_runtime_param_message_api() {
    let js = event_horizon_js();
    assert!(
        js.contains("addEventListener(\"message\""),
        "event-horizon.js must subscribe to window 'message' events for runtime tweaks"
    );
    // External callers (settings panel, overview-chat-ui) post objects
    // shaped `{ type: "param", name, value }`. Pin the contract.
    for needle in [
        "ROTATION_SPEED",
        "DISK_INTENSITY",
        "STARS_ONLY",
        "TILT",
        "ROTATE",
        "BH_CENTER_X",
        "BH_CENTER_Y",
        "BH_SCALE",
        "CHROMATIC",
    ] {
        assert!(
            js.contains(needle),
            "event-horizon.js runtime API missing parameter `{needle}`"
        );
    }
}

#[test]
fn event_horizon_tsx_and_js_share_default_parameter_values() {
    let tsx = event_horizon_tsx();
    let js = event_horizon_js();
    // Defaults documented in event-horizon.js as "match the React
    // source — keep in sync". If a maintainer drifts one without the
    // other the shader will look subtly different on device vs in a
    // bundled React deployment.
    let pairs = [
        ("rotationSpeedVal", " 0.3"),
        ("diskIntensityVal", " 1.0"),
        ("starsOnlyVal", " 0.0"),
        ("tiltVal", " -0.2"),
        ("rotateVal", " 0.0"),
        ("bhCenterX", " 0.0"),
        ("bhCenterY", " 0.0"),
        ("bhScaleVal", " 0.0"),
        ("chromaticVal", " 0.0"),
    ];
    for (name, value) in pairs {
        let needle = format!("{name} ={value}");
        assert!(
            tsx.contains(&needle),
            "event-horizon.tsx default for `{name}` must be `{value}` (React source)"
        );
        assert!(
            js.contains(&needle),
            "event-horizon.js default for `{name}` must be `{value}` (vanilla port out of sync with React source)"
        );
    }
}

#[test]
fn event_horizon_tsx_and_js_declare_the_same_uniforms() {
    let tsx = event_horizon_tsx();
    let js = event_horizon_js();
    for uniform in [
        "u_time",
        "u_res",
        "u_rotationSpeed",
        "u_diskIntensity",
        "u_starsOnly",
        "u_tilt",
        "u_rotate",
        "u_bhCenter",
        "u_bhScale",
        "u_chromatic",
    ] {
        assert!(
            tsx.contains(uniform),
            "event-horizon.tsx missing uniform `{uniform}` (canonical source)"
        );
        assert!(
            js.contains(uniform),
            "event-horizon.js missing uniform `{uniform}` (vanilla port out of sync)"
        );
    }
}
