use std::process::Command;

use atomos_overview_chat_ui::{
    enter_action, layout_state_for_text, EnterKeyAction, LINE_HEIGHT_PX, MAX_LINES,
};
use gtk::gdk;
use gtk::glib;
use gtk::prelude::*;

use crate::config::INPUT_VERTICAL_INSET_PX;

pub fn build_input_scroller() -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(LINE_HEIGHT_PX + INPUT_VERTICAL_INSET_PX)
        .max_content_height((LINE_HEIGHT_PX * MAX_LINES) + INPUT_VERTICAL_INSET_PX)
        .hexpand(true)
        .build()
}

pub fn wire_input_layout_behavior(input_scroller: &gtk::ScrolledWindow, input: &gtk::TextView) {
    let input_scroller_clone = input_scroller.clone();
    let buffer = input.buffer();
    let initial_layout = layout_state_for_text("");
    input_scroller
        .set_min_content_height(initial_layout.min_content_height + INPUT_VERTICAL_INSET_PX);
    input_scroller
        .set_max_content_height(initial_layout.max_content_height + INPUT_VERTICAL_INSET_PX);
    input_scroller.set_height_request(initial_layout.min_content_height + INPUT_VERTICAL_INSET_PX);
    input_scroller.set_vscrollbar_policy(if initial_layout.needs_scroll {
        gtk::PolicyType::Automatic
    } else {
        gtk::PolicyType::Never
    });

    buffer.connect_changed(move |buf| {
        let start = buf.start_iter();
        let end = buf.end_iter();
        let text = buf.text(&start, &end, true);
        let state = layout_state_for_text(text.as_str());
        input_scroller_clone
            .set_min_content_height(state.min_content_height + INPUT_VERTICAL_INSET_PX);
        input_scroller_clone
            .set_max_content_height(state.max_content_height + INPUT_VERTICAL_INSET_PX);
        input_scroller_clone.set_height_request(state.min_content_height + INPUT_VERTICAL_INSET_PX);
        input_scroller_clone.set_vscrollbar_policy(if state.needs_scroll {
            gtk::PolicyType::Automatic
        } else {
            gtk::PolicyType::Never
        });
    });
}

pub fn wire_enter_submit_behavior(input: &gtk::TextView) {
    let key = gtk::EventControllerKey::new();
    let input_for_key = input.clone();
    key.connect_key_pressed(move |_controller, keyval, _keycode, state| {
        if keyval == gdk::Key::Return {
            let buf = input_for_key.buffer();
            let start = buf.start_iter();
            let end = buf.end_iter();
            let message = buf.text(&start, &end, true).to_string();
            return match enter_action(&message, state.contains(gdk::ModifierType::SHIFT_MASK)) {
                EnterKeyAction::Submit(payload) => {
                    let _ = Command::new("/usr/libexec/atomos-overview-chat-submit")
                        .arg(payload)
                        .status();
                    buf.set_text("");
                    glib::Propagation::Stop
                }
                EnterKeyAction::Noop => glib::Propagation::Stop,
                EnterKeyAction::InsertNewline => glib::Propagation::Proceed,
            };
        }
        glib::Propagation::Proceed
    });
    input.add_controller(key);
}
