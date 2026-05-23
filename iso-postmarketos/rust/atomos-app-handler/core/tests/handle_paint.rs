//! Handle paint contract tests: GTK + egui front-ends must share the core
//! layout/colors so the swipe-up affordance is visible on device.

use atomos_app_handler::handle::{
    capsule_corner_radius, layout_handle_paint, DEBUG_TINT, PILL_FILL, PILL_HEIGHT_PX,
    PILL_WIDTH_PX, STRIP_SCRIM,
};

#[test]
fn handle_constants_are_stable_for_installer_grep() {
    assert_eq!(PILL_WIDTH_PX, 150.0);
    assert_eq!(PILL_HEIGHT_PX, 4.0);
    assert!(STRIP_SCRIM.a > 0.0, "production handle must not be fully transparent");
    assert!(PILL_FILL.a > 0.0, "pill must be visible over running apps");
    assert!(DEBUG_TINT.a > 0.0, "debug tint must remain opt-in visible");
}

#[test]
fn default_handle_height_from_core_fits_pill() {
    use atomos_app_handler::DEFAULT_HANDLE_HEIGHT_PX;

    let plan = layout_handle_paint(420.0, DEFAULT_HANDLE_HEIGHT_PX as f64)
        .expect("default handle height must layout");
    assert_eq!(plan.pill.width, PILL_WIDTH_PX);
    assert_eq!(plan.pill.height, PILL_HEIGHT_PX);
    assert!(
        plan.pill.y + plan.pill.height <= plan.strip.height,
        "pill must fit inside the strip"
    );
}

#[test]
fn pill_stays_horizontally_centered_for_common_phone_widths() {
    for width in [360.0, 390.0, 420.0, 720.0] {
        let plan = layout_handle_paint(width, 24.0).expect("phone width");
        let center = plan.pill.x + plan.pill.width / 2.0;
        assert!(
            (center - width / 2.0).abs() < f64::EPSILON,
            "pill must stay centered at width={width}"
        );
    }
}

#[test]
fn capsule_radius_never_exceeds_half_dimensions() {
    let plan = layout_handle_paint(420.0, 24.0).unwrap();
    let r = capsule_corner_radius(plan.pill.width, plan.pill.height);
    assert!(r <= plan.pill.width / 2.0);
    assert!(r <= plan.pill.height / 2.0);
}
