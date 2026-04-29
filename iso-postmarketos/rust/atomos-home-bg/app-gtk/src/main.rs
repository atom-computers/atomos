//! Binary entry point for `atomos-home-bg`.
//!
//! Linux-only — this surface targets wlr-layer-shell on phosh/phoc. On other
//! hosts we compile a no-op stub so `cargo check` at the workspace level keeps
//! working (core crate still exercises the logic via unit tests).

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::run()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!(
        "atomos-home-bg: this binary only runs on Linux (needs gtk4 + webkit2gtk-6.0 + layer-shell). \
         Use the core tests for cross-platform iteration."
    );
}
