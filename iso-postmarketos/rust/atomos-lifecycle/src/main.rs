//! atomos-lifecycle daemon binary.
//!
//! Replaces the Phosh C spawn orchestration in `home.c`:
//!   - `atomos_phosh_sync_overview_chat_ui_lifecycle`
//!   - `atomos_phosh_sync_home_bg_layer`
//!
//! Uses the pure decision logic in `atomos_lifecycle` to determine the
//! correct layer for chat-ui and home-bg, then spawns/restarts them
//! with the correct `ATOMOS_*_LAYER` environment variable.
//!
//! Mode 1 (one-shot): reads env vars set by Phosh and exits.
//!   Activated when `ATOMOS_LIFECYCLE_ENABLE_RUNTIME=1` with no `--daemon` flag.
//!
//! Mode 2 (daemon): connects to Wayland for toplevel tracking and D-Bus
//!   for lock state monitoring, stays running. Reads drag state from env
//!   vars on each `ATOMOS_LIFECYCLE_DAEMON_PING` write from Phosh.

use atomos_lifecycle::daemon::{dispatch_commands, LifecycleDaemon, LifecycleEvent, DispatchResult};
use atomos_lifecycle::input::{drag_state_from_env, lock_state_from_env, toplevel_count_from_env};
use atomos_lifecycle::process;
use atomos_lifecycle::HomeInputs;
use std::env;
use std::process::Command;

fn main() {
    let runtime_env = "ATOMOS_LIFECYCLE_ENABLE_RUNTIME";
    if env::var(runtime_env).as_deref() != Ok("1") {
        eprintln!("atomos-lifecycle: {runtime_env} not set to 1; exiting");
        return;
    }

    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(|s| s.as_str()) == Some("--daemon") {
        #[cfg(all(feature = "daemon", target_os = "linux"))]
        {
            eprintln!("atomos-lifecycle: running in daemon mode");
            run_daemon();
        }
        #[cfg(not(all(feature = "daemon", target_os = "linux")))]
        {
            eprintln!("atomos-lifecycle: daemon mode requires the 'daemon' feature on Linux");
            std::process::exit(1);
        }
    } else {
        eprintln!("atomos-lifecycle: WARNING: one-shot mode is deprecated; use --daemon mode");
        eprintln!("atomos-lifecycle: running in one-shot mode from env");
        run_oneshot_from_env();
    }
}

fn run_oneshot_from_env() {
    let drag = drag_state_from_env();
    let locked = lock_state_from_env();
    let toplevel_count = toplevel_count_from_env();

    let inputs = HomeInputs {
        drag_state: drag,
        locked,
        toplevel_count,
    };

    let mut daemon = LifecycleDaemon::with_inputs(inputs);
    let transition = daemon.process_event(&LifecycleEvent::InitialSync);

    eprintln!(
        "atomos-lifecycle: drag={:?} locked={:?} toplevels={} → chat={:?} bg={:?}",
        drag, locked, toplevel_count,
        transition.chat_ui, transition.home_bg
    );

    dispatch_transition(&transition);
}

#[cfg(all(feature = "daemon", target_os = "linux"))]
fn run_daemon() {
    use atomos_lifecycle::wayland::ToplevelCounter;
    use atomos_lifecycle::dbus;
    use atomos_lifecycle::HomeDragState;
    use atomos_lifecycle::LockState;
    use std::sync::{Arc, Mutex};

    let mut daemon = LifecycleDaemon::new();

    let daemon = Arc::new(Mutex::new(daemon));
    let daemon_wl = daemon.clone();
    let daemon_dbus = daemon.clone();
    let daemon_drag = daemon.clone();

    {
        let mut d = daemon.lock().unwrap();
        let transition = d.process_event(&LifecycleEvent::InitialSync);
        eprintln!(
            "atomos-lifecycle: initial dispatch chat={:?} bg={:?}",
            transition.chat_ui, transition.home_bg
        );
        dispatch_transition(&transition);
    }

    std::thread::scope(|s| {
        s.spawn(|| {
            if let Err(e) = dbus::watch_lock_state(Box::new(move |state| {
                let mut d = daemon_dbus.lock().unwrap();
                let event = LifecycleEvent::LockChanged(state);
                let transition = d.process_event(&event);
                if transition.chat_ui.is_some() || transition.home_bg.is_some() {
                    eprintln!("atomos-lifecycle: lock={:?} → chat={:?} bg={:?}", state, transition.chat_ui, transition.home_bg);
                    dispatch_transition(&transition);
                }
            })) {
                eprintln!("atomos-lifecycle: dbus lock error: {e}");
            }
        });

        s.spawn(|| {
            if let Err(e) = dbus::watch_drag_state(Box::new(move |state| {
                let mut d = daemon_drag.lock().unwrap();
                let event = LifecycleEvent::DragStateChanged(state);
                let transition = d.process_event(&event);
                if transition.chat_ui.is_some() || transition.home_bg.is_some() {
                    eprintln!("atomos-lifecycle: drag={:?} → chat={:?} bg={:?}", state, transition.chat_ui, transition.home_bg);
                    dispatch_transition(&transition);
                }
            })) {
                eprintln!("atomos-lifecycle: dbus drag error: {e}");
            }
        });

        s.spawn(|| {
            if let Err(e) = ToplevelCounter::run(Box::new(move |count| {
                let mut d = daemon_wl.lock().unwrap();
                let event = LifecycleEvent::ToplevelCountChanged(count);
                let transition = d.process_event(&event);
                if transition.chat_ui.is_some() || transition.home_bg.is_some() {
                    eprintln!("atomos-lifecycle: toplevels={count} → chat={:?} bg={:?}", transition.chat_ui, transition.home_bg);
                    dispatch_transition(&transition);
                }
            })) {
                eprintln!("atomos-lifecycle: wayland error: {e}");
            }
        });

        eprintln!("atomos-lifecycle: daemon running (wayland toplevels + dbus lock + dbus drag)");
    });
}

fn dispatch_transition(transition: &DispatchResult) {
    let (chat_cmd, bg_cmd) = dispatch_commands(transition);
    if let Some(cmd) = chat_cmd {
        run_managed_command(&cmd);
    }
    if let Some(cmd) = bg_cmd {
        run_managed_command(&cmd);
    }
}

fn run_managed_command(cmd: &process::ManagedCommand) {
    let mut command = Command::new(&cmd.argv[0]);
    for arg in &cmd.argv[1..] {
        command.arg(arg);
    }
    for (key, val) in &cmd.env {
        command.env(key, val);
    }

    match command.spawn() {
        Ok(child) => {
            eprintln!("atomos-lifecycle: spawned pid {} {:?}", child.id(), cmd.argv);
        }
        Err(e) => {
            eprintln!("atomos-lifecycle: failed to spawn {:?}: {e}", cmd.argv);
        }
    }
}