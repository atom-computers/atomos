use zbus::blocking::{Connection, MessageIterator};

/// Block until logind sends a Lock or PrepareForSleep(true) signal for
/// the current session. Returns the signal name that fired.
pub fn wait_for_lock_signal() -> Result<&'static str, Box<dyn std::error::Error>> {
    let conn = Connection::system()?;
    let session_path = current_session_path(&conn)?;

    let lock_rule = format!(
        "type='signal',interface='org.freedesktop.login1.Session',member='Lock',path='{session_path}'"
    );
    let sleep_rule =
        "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'";

    conn.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "AddMatch",
        &(lock_rule.as_str(),),
    )?;
    conn.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "AddMatch",
        &(sleep_rule,),
    )?;

    let iter = MessageIterator::from(&conn);
    for msg in iter {
        let msg = msg?;
        let hdr = msg.header();

        let is_lock = hdr.member().is_some_and(|m| m.as_str() == "Lock")
            && hdr
                .interface()
                .is_some_and(|i| i.as_str() == "org.freedesktop.login1.Session");

        let is_sleep = hdr
            .member()
            .is_some_and(|m| m.as_str() == "PrepareForSleep")
            && hdr
                .interface()
                .is_some_and(|i| i.as_str() == "org.freedesktop.login1.Manager");

        if is_lock {
            return Ok("Lock");
        }
        if is_sleep {
            if let Ok((going_to_sleep,)) = msg.body().deserialize::<(bool,)>() {
                if going_to_sleep {
                    return Ok("PrepareForSleep");
                }
            }
        }
    }

    Err("D-Bus message stream ended".into())
}

fn current_session_path(conn: &Connection) -> Result<String, Box<dyn std::error::Error>> {
    if let Ok(sid) = std::env::var("XDG_SESSION_ID") {
        return Ok(format!("/org/freedesktop/login1/session/{sid}"));
    }

    let msg = conn.call_method(
        Some("org.freedesktop.login1"),
        "/org/freedesktop/login1",
        Some("org.freedesktop.login1.Manager"),
        "GetSessionByPID",
        &(std::process::id(),),
    )?;

    let path: zbus::zvariant::OwnedObjectPath = msg.body().deserialize()?;
    Ok(path.to_string())
}

/// Run as a daemon: wait for lock signals in a loop, locking each time.
pub fn run_daemon() -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("atomos-lock-daemon: watching for logind lock signals");
    loop {
        match wait_for_lock_signal() {
            Ok(signal) => {
                eprintln!("atomos-lock-daemon: received {signal}, locking session");
                if let Err(e) = crate::wayland::run_lock() {
                    eprintln!("atomos-lock-daemon: lock failed: {e}");
                }
            }
            Err(e) => {
                eprintln!("atomos-lock-daemon: signal watch error: {e}");
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        }
    }
}
