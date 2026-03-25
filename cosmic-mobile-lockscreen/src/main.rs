mod auth;
mod engine;
mod greetd;
mod greeter;
mod logind;
mod osk;
mod render;
mod spec;
#[cfg(feature = "iced-preview")]
mod ui;
mod wayland;

const GREETER_SYSTEM_USER: &str = "cosmic-greeter";

fn current_username() -> Option<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .ok()
        .or_else(|| {
            let uid = unsafe { libc::getuid() };
            let pw = unsafe { libc::getpwuid(uid) };
            if pw.is_null() {
                return None;
            }
            let name = unsafe { std::ffi::CStr::from_ptr((*pw).pw_name) };
            name.to_str().ok().map(String::from)
        })
}

fn print_usage() {
    eprintln!("cosmic-greeter (AtomOS drop-in replacement)");
    eprintln!();
    eprintln!("Modes (auto-detected from running user):");
    eprintln!("  greeter  Running as '{GREETER_SYSTEM_USER}' -> login screen via greetd IPC");
    eprintln!("  locker   Running as any other user -> session lock daemon via logind");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  (no args)      Auto-detect mode");
    eprintln!("  --lock         Lock the session now (one-shot, locker only)");
    eprintln!("  --daemon       Explicit locker daemon mode");
    eprintln!("  --greeter      Explicit greeter mode");
    eprintln!("  --spec         Print parity spec as JSON");
    eprintln!("  --render-test  Render a lock screen frame to /tmp/lockscreen.data");
    eprintln!("  --help         Show this message");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str());

    // Explicit subcommands take priority over user detection.
    match cmd {
        Some("--help" | "-h") => { print_usage(); return Ok(()); }
        Some("--spec") => {
            let out = serde_json::to_string_pretty(&spec::phosh_parity_spec())?;
            println!("{out}");
            return Ok(());
        }
        Some("--render-test") => {
            let r = render::Renderer::new();
            let data = r.render(1080, 2340, 3, "");
            std::fs::write("/tmp/lockscreen.data", &data)?;
            println!("Wrote 1080x2340 ARGB8888 frame to /tmp/lockscreen.data");
            println!("View: ffplay -f rawvideo -pixel_format bgra -video_size 1080x2340 /tmp/lockscreen.data");
            return Ok(());
        }
        Some("--lock") => { return wayland::run_lock().map_err(Into::into); }
        Some("--greeter") => { return greeter::run_greeter().map_err(Into::into); }
        Some("--daemon") => {
            eprintln!("cosmic-greeter: entering locker daemon mode");
            return logind::run_daemon().map_err(Into::into);
        }
        Some(other) => {
            eprintln!("cosmic-greeter: unknown option: {other}");
            print_usage();
            std::process::exit(1);
        }
        None => {}
    }

    // No explicit subcommand: auto-detect from running user.
    let is_greeter_user = current_username()
        .map(|u| u == GREETER_SYSTEM_USER)
        .unwrap_or(false);

    if is_greeter_user {
        greeter::run_greeter()?;
    } else {
        eprintln!("cosmic-greeter: entering locker daemon mode");
        logind::run_daemon()?;
    }

    Ok(())
}
