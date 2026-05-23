//! Binary entry point for `atomos-app-handler`.
//!
//! Linux-only — this surface targets wlr-layer-shell + wlr-foreign-toplevel
//! on phosh/phoc. On other hosts we compile a no-op stub so workspace-wide
//! `cargo check` keeps working (the core crate is fully cross-platform).

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::run()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!(
        "atomos-app-handler: this binary only runs on Linux (needs gtk4 + \
         gtk4-layer-shell + wlr-foreign-toplevel-management). Use the core \
         tests / egui preview for cross-platform iteration."
    );
}
