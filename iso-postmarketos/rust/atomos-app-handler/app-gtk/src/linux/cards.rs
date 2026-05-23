//! Card-row widget for the switcher overlay.
//!
//! v1 cards are colored swatches with the app title + app_id underneath —
//! no live thumbnails. Thumbnails depend on `wlr-screencopy` which is a
//! v2 follow-up. The placeholder swatch color is derived deterministically
//! from `app_id` so a maintainer recognises "the Firefox card" by hue.

use atomos_app_handler::{
    evaluate_card_dismiss, CardOutcome, GestureConfig, ToplevelEntry,
};
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

use super::wayland::{ToplevelHandle, WaylandClient};
use super::OverlayController;

/// Owns the `gtk::ScrolledWindow` containing the card row and keeps the
/// current snapshot in sync with the Wayland thread. All mutation goes
/// through `update_snapshot`; the widget is never rebuilt outside this
/// entry point so the gesture controllers don't have to chase stale
/// widget refs.
pub struct CardsController {
    container: gtk::ScrolledWindow,
    row: gtk::Box,
    overlay: Rc<OverlayController>,
    gestures: GestureConfig,
    /// Held so the wayland thread stays alive for as long as the card UI
    /// does. Not read after construction in v1 — wayland actions go
    /// through the per-card `ToplevelHandle::activate()` / `close()`
    /// shortcuts. Kept for future re-bind hooks (seat changes, etc.).
    #[allow(dead_code)]
    wayland: Option<WaylandClient>,
    snapshot: RefCell<Vec<(ToplevelEntry, ToplevelHandle)>>,
}

impl CardsController {
    pub fn new(overlay: Rc<OverlayController>, wayland: Option<WaylandClient>) -> Self {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 16);
        row.set_halign(gtk::Align::Center);
        row.set_valign(gtk::Align::Center);
        row.set_margin_start(24);
        row.set_margin_end(24);

        let container = gtk::ScrolledWindow::new();
        container.set_hscrollbar_policy(gtk::PolicyType::Automatic);
        container.set_vscrollbar_policy(gtk::PolicyType::Never);
        container.set_propagate_natural_height(true);
        container.set_min_content_height(280);
        container.set_child(Some(&row));

        Self {
            container,
            row,
            gestures: overlay.gestures,
            overlay,
            wayland,
            snapshot: RefCell::new(Vec::new()),
        }
    }

    pub fn widget(&self) -> &gtk::ScrolledWindow {
        &self.container
    }

    /// Replace the card row with the latest Wayland snapshot. Called from
    /// `glib::spawn_future_local` after each `WaylandClient::snapshots()`
    /// message arrives.
    pub fn update_snapshot(&self, snapshot: Vec<(ToplevelEntry, ToplevelHandle)>) {
        // Clear existing children. GTK4 doesn't have a single-call clear
        // for `gtk::Box`, so we walk from the first child until None.
        while let Some(child) = self.row.first_child() {
            self.row.remove(&child);
        }

        for (entry, handle) in &snapshot {
            let card = build_card(entry);
            wire_card_gestures(
                &card,
                entry.clone(),
                handle.clone(),
                self.gestures,
                self.overlay.clone(),
            );
            self.row.append(&card);
        }
        *self.snapshot.borrow_mut() = snapshot;

        // If the snapshot is empty and the overlay is open, fall back to
        // closed — a switcher with no apps to switch to is just dead
        // space, and the user has already invested a swipe in opening it.
        if self.snapshot.borrow().is_empty() && self.overlay.is_open() {
            self.overlay.close();
        }
    }
}

fn build_card(entry: &ToplevelEntry) -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
    card.add_css_class("atomos-app-handler-card");
    if entry.activated {
        card.add_css_class("activated");
    }
    card.set_size_request(200, 280);

    let swatch = gtk::Box::new(gtk::Orientation::Vertical, 0);
    swatch.add_css_class("atomos-app-handler-card-swatch");
    swatch.set_vexpand(true);
    swatch.set_hexpand(true);
    let [r, g, b] = swatch_rgb(&entry.app_id);
    let css = format!(
        "background: rgb({r}, {g}, {b}); border-radius: 12px; min-height: 180px;",
    );
    let provider = gtk::CssProvider::new();
    provider.load_from_data(&css);
    swatch
        .style_context()
        .add_provider(&provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    card.append(&swatch);

    let title = gtk::Label::new(Some(entry.display_label()));
    title.add_css_class("atomos-app-handler-card-title");
    title.set_halign(gtk::Align::Start);
    title.set_xalign(0.0);
    title.set_wrap(true);
    title.set_max_width_chars(20);
    card.append(&title);

    let app_id_label = gtk::Label::new(Some(&entry.app_id));
    app_id_label.add_css_class("atomos-app-handler-card-appid");
    app_id_label.set_halign(gtk::Align::Start);
    app_id_label.set_xalign(0.0);
    card.append(&app_id_label);

    card
}

fn wire_card_gestures(
    card: &gtk::Box,
    entry: ToplevelEntry,
    handle: ToplevelHandle,
    gestures: GestureConfig,
    overlay: Rc<OverlayController>,
) {
    // Per-card drag: cumulative dy is tracked here and evaluated in the
    // core helper on drag-end. The card itself stays in place visually for
    // v1 — adding a translation that tracks the live drag is a polish
    // item for v2 once we have an `egui-style` per-card transform helper.
    let dy = Rc::new(Cell::new(0.0_f64));

    let drag = gtk::GestureDrag::new();
    drag.set_button(0);

    let dy_begin = dy.clone();
    drag.connect_drag_begin(move |_, _, _| {
        dy_begin.set(0.0);
    });

    let dy_update = dy.clone();
    drag.connect_drag_update(move |_, _ox, oy| {
        dy_update.set(oy);
    });

    let dy_end = dy.clone();
    let handle_for_end = handle.clone();
    let overlay_for_end = overlay.clone();
    let entry_id = entry.id;
    drag.connect_drag_end(move |_, _ox, _oy| {
        let dy_value = dy_end.replace(0.0);
        match evaluate_card_dismiss(0.0, dy_value, &gestures) {
            CardOutcome::Close => {
                eprintln!(
                    "atomos-app-handler: card close id={entry_id} dy={dy_value:.1}"
                );
                handle_for_end.close();
            }
            CardOutcome::Activate => {
                eprintln!(
                    "atomos-app-handler: card activate id={entry_id} dy={dy_value:.1}"
                );
                handle_for_end.activate();
                overlay_for_end.close();
            }
            CardOutcome::Ignore => {}
        }
    });

    card.add_controller(drag);
}

/// Same deterministic hash → RGB swatch the egui preview uses. Keeping the
/// algorithm identical means a maintainer can cross-check colors between
/// `cargo run -p atomos-app-handler-egui` and a real device side-by-side
/// without having to mentally translate hashes.
fn swatch_rgb(app_id: &str) -> [u8; 3] {
    let mut h: u32 = 5381;
    for b in app_id.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    let hue = (h % 360) as f32;
    hsv_to_rgb(hue, 0.55, 0.75)
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> [u8; 3] {
    let c = v * s;
    let h_prime = (h % 360.0) / 60.0;
    let x = c * (1.0 - (h_prime % 2.0 - 1.0).abs());
    let (r, g, b) = match h_prime as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = v - c;
    [
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8,
    ]
}
