//! Source-level wiring contract for the gtk4 entry point in
//! [`app-gtk/src/linux.rs`](../../app-gtk/src/linux.rs).
//!
//! Reproduces — and pins the fix to — the device-side regression where
//! `Exec=/usr/libexec/atomos-app-handler --start` (the autostart contract
//! emitted by `install-app-handler.sh`) reached the binary, gtk's own
//! option parser inside `g_application_run` rejected `--start` with:
//!
//! ```text
//! atomos-app-handler: entering gtk::Application::run main loop
//! Unknown option --start
//! atomos-app-handler: gtk::Application::run returned exit_code=ExitCode(1)
//! ```
//!
//! …and the autostart-spawned process died before the bottom-edge
//! `handle_window` was ever `present()`'d. Symptom: no swipe-up bar over
//! the running app, captured by `diagnose-app-handler.sh`'s
//! `Process / runtime state -> atomos-app-handler running (handle bar)`
//! FAIL.
//!
//! The contract: `linux.rs::run` MUST hand gtk a sanitized argv via
//! `gtk_argv_for_run` (which preserves only `argv[0]`) — never bare
//! `app.run()`, which would let our private lifecycle flags leak into
//! gtk's option parser.

const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");

#[test]
fn linux_run_uses_gtk_argv_for_run_helper() {
    assert!(
        LINUX_RS.contains("gtk_argv_for_run"),
        "app-gtk/src/linux.rs must compute the argv handed to gtk via \
         atomos_app_handler::gtk_argv_for_run so our private lifecycle \
         flags (--start / --show / launch) never reach g_application_run's \
         option parser. The bug this guards: 'Unknown option --start' on \
         autostart, no handle bar above running app",
    );
}

#[test]
fn linux_run_does_not_call_bare_application_run_on_app() {
    // Allow `app.run()` to still appear inside comments or doc strings,
    // but the executable line must use `run_with_args`. Detect the bug
    // pattern by looking for a line that ends with `app.run()` /
    // `app.run();` after trimming leading whitespace — that is the exact
    // form the buggy version had.
    let bare_run_present = LINUX_RS.lines().any(|line| {
        let trimmed = line.trim_start();
        // Skip comments — false-positive inside doc-comments / examples.
        if trimmed.starts_with("//") || trimmed.starts_with("///") {
            return false;
        }
        trimmed.contains("= app.run();")
            || trimmed.starts_with("app.run();")
            || trimmed.contains("= app.run()")
                && !trimmed.contains("run_with_args")
    });
    assert!(
        !bare_run_present,
        "app-gtk/src/linux.rs must not call bare `app.run()` — that pipes \
         std::env::args() through gtk's option parser, which rejects \
         `--start` with exit_code=1 and breaks the autostart bar. Use \
         `app.run_with_args(&gtk_argv_for_run(...))` instead",
    );
}

#[test]
fn linux_run_calls_run_with_args() {
    assert!(
        LINUX_RS.contains("run_with_args"),
        "app-gtk/src/linux.rs must dispatch to gtk via run_with_args so the \
         argv is sanitized; bare app.run() reads std::env::args() directly \
         and trips gtk's 'Unknown option --start' path on autostart",
    );
}
