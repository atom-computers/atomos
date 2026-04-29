//! Shape-check the placeholder HTML shipped under `data/atomos-home-bg/`.
//!
//! Purpose: the combined preview
//! (`scripts/home-bg/preview-home-bg-and-overview-chat-ui.sh`) relies on this
//! file to put something *visually obvious* on screen so a human can tell
//! whether home-bg is actually rendering beneath the overview-chat-ui
//! surface. If someone trims the HTML back down to an empty page or drops
//! the animation, the preview silently stops being a meaningful test — this
//! suite catches that at `cargo test` time.

use std::path::PathBuf;

fn placeholder_html() -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let content_path = manifest_dir
        .join("..")
        .join("..")
        .join("..")
        .join("data/atomos-home-bg/index.html");
    assert!(
        content_path.exists(),
        "placeholder HTML missing at {}",
        content_path.display()
    );
    std::fs::read_to_string(&content_path).unwrap_or_else(|e| {
        panic!(
            "failed to read placeholder HTML at {}: {e}",
            content_path.display()
        )
    })
}

#[test]
fn placeholder_has_solid_white_background() {
    let html = placeholder_html();
    let has_white =
        html.contains("background: #ffffff") || html.contains("background:#ffffff");
    assert!(
        has_white,
        "placeholder must set an opaque white background for visual preview testing"
    );
}

#[test]
fn placeholder_has_animation_driver() {
    let html = placeholder_html();
    assert!(
        html.contains("requestAnimationFrame"),
        "placeholder must drive an animation via requestAnimationFrame so preview \
         confirms the JS runtime is live"
    );
}

#[test]
fn placeholder_has_canvas_and_stage_element() {
    let html = placeholder_html();
    assert!(html.contains("<canvas"), "placeholder must use a <canvas> element");
    assert!(
        html.contains("id=\"stage\""),
        "placeholder must expose a stage canvas id used by the animation"
    );
}

#[test]
fn placeholder_has_live_hud_counter() {
    let html = placeholder_html();
    assert!(html.contains("id=\"frame\""), "placeholder must show a frame counter");
    assert!(html.contains("id=\"fps\""), "placeholder must show an fps readout");
}

#[test]
fn placeholder_labels_itself_as_preview_test_content() {
    let html = placeholder_html();
    assert!(
        html.contains("atomos-home-bg preview test"),
        "placeholder must identify itself so preview runs don't look like real React output"
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
