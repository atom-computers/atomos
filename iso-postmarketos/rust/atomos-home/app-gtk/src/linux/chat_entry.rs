//! "Ask AtomOS" chat entry widget.
//!
//! A GtkEntry with placeholder text "Ask AtomOS" and the `atomos-chat-input`
//! CSS class. Visible only when the home surface is unfolded and the app grid
//! is hidden. Submitting the entry spawns `/usr/libexec/atomos-overview-chat-submit`
//! with the entry text as an argument.

#![cfg(target_os = "linux")]

use gtk::prelude::*;

pub const CHAT_ENTRY_CSS_CLASS: &str = "atomos-chat-input";
pub const CHAT_WRAP_CSS_CLASS: &str = "atomos-chat-wrap";
pub const CHAT_PLACEHOLDER: &str = "Ask AtomOS";
pub const CHAT_SUBMIT_PATH: &str = "/usr/libexec/atomos-overview-chat-submit";

pub fn create_chat_entry() -> gtk::Entry {
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some(CHAT_PLACEHOLDER));
    entry.add_css_class(CHAT_ENTRY_CSS_CLASS);
    entry.set_hexpand(true);

    entry.connect_activate(|entry| {
        let text = entry.text().to_string();
        if !text.is_empty() {
            spawn_chat_submit(&text);
            entry.set_text("");
        }
    });

    entry
}

pub fn create_chat_wrap(entry: &gtk::Entry) -> gtk::Box {
    let wrap = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    wrap.add_css_class(CHAT_WRAP_CSS_CLASS);
    wrap.append(entry);
    wrap
}

fn spawn_chat_submit(text: &str) {
    let _ = std::process::Command::new(CHAT_SUBMIT_PATH)
        .arg(text)
        .env("ATOMOS_CHAT_ENTRY_MODE", "1")
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_submit_path_is_absolute() {
        assert!(CHAT_SUBMIT_PATH.starts_with('/'));
    }

    #[test]
    fn css_classes_match_stylesheet() {
        assert_eq!(CHAT_ENTRY_CSS_CLASS, "atomos-chat-input");
        assert_eq!(CHAT_WRAP_CSS_CLASS, "atomos-chat-wrap");
    }

    #[test]
    fn placeholder_text_is_nonempty() {
        assert!(!CHAT_PLACEHOLDER.is_empty());
    }
}