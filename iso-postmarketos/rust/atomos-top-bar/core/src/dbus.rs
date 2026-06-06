use zbus::{Connection, proxy};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use futures::stream::StreamExt;
use crate::TopBarState;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, ObjectPath};

#[proxy(
    interface = "org.freedesktop.UPower.Device",
    default_service = "org.freedesktop.UPower",
    default_path = "/org/freedesktop/UPower/devices/DisplayDevice"
)]
trait UPowerDevice {
    #[zbus(property)]
    fn percentage(&self) -> zbus::Result<f64>;

    #[zbus(property)]
    fn state(&self) -> zbus::Result<u32>;
}

#[proxy(
    interface = "org.freedesktop.DBus.ObjectManager",
    default_service = "org.freedesktop.ModemManager1",
    default_path = "/org/freedesktop/ModemManager1"
)]
trait MMObjectManager {
    fn get_managed_objects(&self) -> zbus::Result<HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>>;
}

#[proxy(
    interface = "org.freedesktop.ModemManager1.Modem",
    default_service = "org.freedesktop.ModemManager1"
)]
trait MMModem {
    #[zbus(property)]
    fn signal_quality(&self) -> zbus::Result<(u32, bool)>;
}

#[proxy(
    interface = "org.freedesktop.ModemManager1.Modem.Modem3gpp",
    default_service = "org.freedesktop.ModemManager1"
)]
trait MMModem3gpp {
    #[zbus(property)]
    fn operator_name(&self) -> zbus::Result<String>;
}

#[proxy(
    interface = "org.ofono.Manager",
    default_service = "org.ofono",
    default_path = "/"
)]
trait OfonoManager {
    fn get_modems(&self) -> zbus::Result<Vec<(OwnedObjectPath, HashMap<String, OwnedValue>)>>;
}

#[proxy(
    interface = "org.ofono.NetworkRegistration",
    default_service = "org.ofono"
)]
trait OfonoNetReg {
    #[zbus(property)]
    fn name(&self) -> zbus::Result<String>;

    #[zbus(property)]
    fn strength(&self) -> zbus::Result<u8>;
}

fn map_pct_to_bars(pct: u32) -> u8 {
    if pct == 0 {
        0
    } else if pct > 80 {
        4
    } else if pct > 60 {
        3
    } else if pct > 40 {
        2
    } else if pct > 20 {
        1
    } else {
        0
    }
}

pub async fn start_dbus_listener(state: Arc<Mutex<TopBarState>>) {
    // Attempt to connect to the System DBus
    let conn_result = Connection::system().await;
    let conn = match conn_result {
        Ok(c) => c,
        Err(e) => {
            eprintln!("AtomOS: Could not connect to system DBus (Expected on macOS). Falling back to mock hardware data. Error: {}", e);
            return;
        }
    };

    println!("AtomOS: Connected to system DBus successfully!");

    // Spawn UPower listener task
    let upower_conn = conn.clone();
    let upower_state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = start_upower_listener(&upower_conn, upower_state).await {
            eprintln!("AtomOS: UPower listener error: {}", e);
        }
    });

    // Spawn ModemManager listener task
    let mm_conn = conn.clone();
    let mm_state = state.clone();
    tokio::spawn(async move {
        start_mm_listener(&mm_conn, mm_state).await;
    });

    // Spawn ofono listener task
    let ofono_conn = conn.clone();
    let ofono_state = state.clone();
    tokio::spawn(async move {
        start_ofono_listener(&ofono_conn, ofono_state).await;
    });
}

async fn start_upower_listener(conn: &Connection, state: Arc<Mutex<TopBarState>>) -> zbus::Result<()> {
    let proxy = UPowerDeviceProxy::new(conn).await?;

    // Initial read
    if let Ok(pct) = proxy.percentage().await {
        if let Ok(mut s) = state.lock() {
            s.battery_level = (pct / 100.0) as f32;
        }
    }
    if let Ok(st) = proxy.state().await {
        if let Ok(mut s) = state.lock() {
            s.is_charging = st == 1 || st == 4; // 1 = Charging, 4 = Fully charged
        }
    }

    // Subscribe to changes
    let mut pct_stream = proxy.receive_percentage_changed().await;
    let mut state_stream = proxy.receive_state_changed().await;

    loop {
        tokio::select! {
            Some(pct_changed) = pct_stream.next() => {
                if let Ok(pct) = pct_changed.get().await {
                    if let Ok(mut s) = state.lock() {
                        s.battery_level = (pct / 100.0) as f32;
                    }
                }
            }
            Some(state_changed) = state_stream.next() => {
                if let Ok(st) = state_changed.get().await {
                    if let Ok(mut s) = state.lock() {
                        s.is_charging = st == 1 || st == 4;
                    }
                }
            }
        }
    }
}

async fn start_mm_listener(conn: &Connection, state: Arc<Mutex<TopBarState>>) {
    let manager = match MMObjectManagerProxy::new(conn).await {
        Ok(m) => m,
        Err(_) => return,
    };

    let mut modem_path_str = "/org/freedesktop/ModemManager1/Modem/0".to_string();
    if let Ok(objects) = manager.get_managed_objects().await {
        for (path, interfaces) in objects {
            if interfaces.contains_key("org.freedesktop.ModemManager1.Modem") {
                modem_path_str = path.as_str().to_string();
                break;
            }
        }
    }

    let path = match ObjectPath::try_from(modem_path_str.as_str()) {
        Ok(p) => p,
        Err(_) => return,
    };

    let modem_proxy = match MMModemProxy::builder(conn).path(path.clone()).unwrap().build().await {
        Ok(p) => p,
        Err(_) => return,
    };

    let modem_3gpp_proxy = match MMModem3gppProxy::builder(conn).path(path).unwrap().build().await {
        Ok(p) => p,
        Err(_) => return,
    };

    // Initial read
    if let Ok(sig) = modem_proxy.signal_quality().await {
        let bars = map_pct_to_bars(sig.0);
        if let Ok(mut s) = state.lock() {
            s.signal_bars = bars;
        }
    }
    if let Ok(op) = modem_3gpp_proxy.operator_name().await {
        if let Ok(mut s) = state.lock() {
            s.carrier_name = op;
        }
    }

    // Streams
    let mut sig_stream = modem_proxy.receive_signal_quality_changed().await;
    let mut op_stream = modem_3gpp_proxy.receive_operator_name_changed().await;

    loop {
        tokio::select! {
            Some(sig_changed) = sig_stream.next() => {
                let res: zbus::Result<(u32, bool)> = sig_changed.get().await;
                if let Ok(sig) = res {
                    let bars = map_pct_to_bars(sig.0);
                    if let Ok(mut s) = state.lock() {
                        s.signal_bars = bars;
                    }
                }
            }
            Some(op_changed) = op_stream.next() => {
                let res: zbus::Result<String> = op_changed.get().await;
                if let Ok(op) = res {
                    if let Ok(mut s) = state.lock() {
                        s.carrier_name = op;
                    }
                }
            }
        }
    }
}

async fn start_ofono_listener(conn: &Connection, state: Arc<Mutex<TopBarState>>) {
    let manager = match OfonoManagerProxy::new(conn).await {
        Ok(m) => m,
        Err(_) => return,
    };

    let mut netreg_path_str = String::new();
    if let Ok(modems) = manager.get_modems().await {
        if let Some((path, _)) = modems.first() {
            netreg_path_str = format!("{}/netreg", path.as_str());
        }
    }

    if netreg_path_str.is_empty() {
        return;
    }

    let path = match ObjectPath::try_from(netreg_path_str.as_str()) {
        Ok(p) => p,
        Err(_) => return,
    };

    let netreg_proxy = match OfonoNetRegProxy::builder(conn).path(path).unwrap().build().await {
        Ok(p) => p,
        Err(_) => return,
    };

    // Initial read
    if let Ok(strength) = netreg_proxy.strength().await {
        let bars = map_pct_to_bars(strength as u32);
        if let Ok(mut s) = state.lock() {
            s.signal_bars = bars;
        }
    }
    if let Ok(op) = netreg_proxy.name().await {
        if let Ok(mut s) = state.lock() {
            s.carrier_name = op;
        }
    }

    // Streams
    let mut strength_stream = netreg_proxy.receive_strength_changed().await;
    let mut name_stream = netreg_proxy.receive_name_changed().await;

    loop {
        tokio::select! {
            Some(str_changed) = strength_stream.next() => {
                let res: zbus::Result<u8> = str_changed.get().await;
                if let Ok(strength) = res {
                    let bars = map_pct_to_bars(strength as u32);
                    if let Ok(mut s) = state.lock() {
                        s.signal_bars = bars;
                    }
                }
            }
            Some(name_changed) = name_stream.next() => {
                let res: zbus::Result<String> = name_changed.get().await;
                if let Ok(name) = res {
                    if let Ok(mut s) = state.lock() {
                        s.carrier_name = name;
                    }
                }
            }
        }
    }
}
