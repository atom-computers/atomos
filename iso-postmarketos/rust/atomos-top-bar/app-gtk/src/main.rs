//! Binary entry point for `atomos-top-bar`.
//!
//! Linux-only — this surface targets wlr-layer-shell on phosh/phoc. On other
//! hosts we compile a no-op stub.

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::run()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!(
        "atomos-top-bar: this binary only runs on Linux (needs gtk4 + layer-shell)."
    );
}
