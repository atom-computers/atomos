use std::os::unix::io::{AsFd, FromRawFd, OwnedFd};
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_keyboard, wl_output, wl_registry, wl_seat, wl_shm,
    wl_shm_pool, wl_surface, wl_touch,
};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum};
use wayland_protocols::ext::session_lock::v1::client::{
    ext_session_lock_manager_v1, ext_session_lock_surface_v1, ext_session_lock_v1,
};

use crate::auth;
use crate::render::{Renderer, MAX_PIN_DOTS};

// Linux evdev keycodes
const KEY_BACKSPACE: u32 = 14;
const KEY_ENTER: u32 = 28;
const KEY_KP_ENTER: u32 = 96;
const KEY_0: u32 = 11;
const KEY_1: u32 = 2;
const KEY_9: u32 = 10;
const KEY_KP0: u32 = 82;
const KEY_KP1: u32 = 79;
const KEY_KP9: u32 = 87;

struct ShmBuffer {
    _pool: wl_shm_pool::WlShmPool,
    buffer: wl_buffer::WlBuffer,
    _fd: OwnedFd,
    ptr: *mut u8,
    len: usize,
}

impl ShmBuffer {
    fn new(
        shm: &wl_shm::WlShm,
        qh: &QueueHandle<LockClient>,
        width: u32,
        height: u32,
    ) -> Self {
        let stride = width * 4;
        let size = (stride * height) as usize;

        let fd = create_shm_fd();
        unsafe { libc::ftruncate(fd.as_fd().as_raw_fd(), size as libc::off_t) };

        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd.as_fd().as_raw_fd(),
                0,
            )
        };
        assert_ne!(ptr, libc::MAP_FAILED);

        let pool = shm.create_pool(fd.as_fd(), size as i32, qh, ());
        let buffer = pool.create_buffer(
            0,
            width as i32,
            height as i32,
            stride as i32,
            wl_shm::Format::Argb8888,
            qh,
            (),
        );

        Self {
            _pool: pool,
            buffer,
            _fd: fd,
            ptr: ptr as *mut u8,
            len: size,
        }
    }

    fn write(&self, data: &[u8]) {
        assert!(data.len() <= self.len);
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), self.ptr, data.len()) };
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
    }
}

use std::os::unix::io::AsRawFd;

fn create_shm_fd() -> OwnedFd {
    #[cfg(target_os = "linux")]
    {
        let name = c"atomos-lockscreen";
        let fd = unsafe { libc::memfd_create(name.as_ptr(), 1 /* MFD_CLOEXEC */) };
        assert!(fd >= 0, "memfd_create failed");
        return unsafe { OwnedFd::from_raw_fd(fd) };
    }
    #[cfg(not(target_os = "linux"))]
    {
        use std::os::unix::io::IntoRawFd;
        let f = tempfile().expect("tmpfile for shm");
        unsafe { OwnedFd::from_raw_fd(f.into_raw_fd()) }
    }
}

#[cfg(not(target_os = "linux"))]
fn tempfile() -> std::io::Result<std::fs::File> {
    let path = std::env::temp_dir().join(format!("atomos-lock-{}", std::process::id()));
    let f = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)?;
    let _ = std::fs::remove_file(&path);
    Ok(f)
}

struct LockSurface {
    surface: wl_surface::WlSurface,
    _lock_surface: ext_session_lock_surface_v1::ExtSessionLockSurfaceV1,
    width: u32,
    height: u32,
    configured: bool,
    buffer: Option<ShmBuffer>,
}

struct OutputInfo {
    output: wl_output::WlOutput,
    #[allow(dead_code)]
    global_name: u32,
}

pub struct LockClient {
    running: bool,
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    seat: Option<wl_seat::WlSeat>,
    #[allow(dead_code)]
    keyboard: Option<wl_keyboard::WlKeyboard>,
    #[allow(dead_code)]
    touch: Option<wl_touch::WlTouch>,
    lock_manager: Option<ext_session_lock_manager_v1::ExtSessionLockManagerV1>,
    lock: Option<ext_session_lock_v1::ExtSessionLockV1>,
    locked: bool,

    outputs: Vec<OutputInfo>,
    surfaces: Vec<LockSurface>,

    pin: String,
    error_msg: String,
    needs_render: bool,

    renderer: Renderer,

    // Touch state: last down position for hit-testing keypad buttons.
    touch_x: f64,
    touch_y: f64,
}

impl LockClient {
    fn new() -> Self {
        Self {
            running: true,
            compositor: None,
            shm: None,
            seat: None,
            keyboard: None,
            touch: None,
            lock_manager: None,
            lock: None,
            locked: false,
            outputs: Vec::new(),
            surfaces: Vec::new(),
            pin: String::new(),
            error_msg: String::new(),
            needs_render: false,
            renderer: Renderer::new(),
            touch_x: 0.0,
            touch_y: 0.0,
        }
    }

    fn create_lock_surfaces(&mut self, qh: &QueueHandle<Self>) {
        let compositor = self.compositor.as_ref().expect("no wl_compositor");
        let lock = self.lock.as_ref().expect("no session lock");

        for (idx, output_info) in self.outputs.iter().enumerate() {
            let surface = compositor.create_surface(qh, ());
            let lock_surface = lock.get_lock_surface(&surface, &output_info.output, qh, idx);
            self.surfaces.push(LockSurface {
                surface,
                _lock_surface: lock_surface,
                width: 0,
                height: 0,
                configured: false,
                buffer: None,
            });
        }
    }

    fn render_surface(&mut self, idx: usize, qh: &QueueHandle<Self>) {
        let surf = &self.surfaces[idx];
        if !surf.configured || surf.width == 0 || surf.height == 0 {
            return;
        }

        let data = self
            .renderer
            .render(surf.width, surf.height, self.pin.len(), &self.error_msg);

        let shm = self.shm.as_ref().expect("no wl_shm");
        let buf = ShmBuffer::new(shm, qh, surf.width, surf.height);
        buf.write(&data);

        let surf = &mut self.surfaces[idx];
        surf.surface.attach(Some(&buf.buffer), 0, 0);
        surf.surface
            .damage_buffer(0, 0, surf.width as i32, surf.height as i32);
        surf.surface.commit();
        surf.buffer = Some(buf);
    }

    fn render_all(&mut self, qh: &QueueHandle<Self>) {
        let count = self.surfaces.len();
        for i in 0..count {
            self.render_surface(i, qh);
        }
    }

    fn handle_key_press(&mut self, keycode: u32) {
        let digit = match keycode {
            KEY_1..=KEY_9 => Some((b'0' + (keycode - KEY_1 + 1) as u8) as char),
            KEY_0 => Some('0'),
            KEY_KP0 => Some('0'),
            KEY_KP1..=KEY_KP9 => Some((b'0' + (keycode - KEY_KP1 + 1) as u8) as char),
            _ => None,
        };

        if let Some(d) = digit {
            if self.pin.len() < MAX_PIN_DOTS {
                self.pin.push(d);
                self.error_msg.clear();
                self.needs_render = true;
            }
            if self.pin.len() == MAX_PIN_DOTS {
                self.try_unlock();
            }
            return;
        }

        match keycode {
            KEY_BACKSPACE => {
                if !self.pin.is_empty() {
                    self.pin.pop();
                    self.error_msg.clear();
                    self.needs_render = true;
                }
            }
            KEY_ENTER | KEY_KP_ENTER => {
                self.try_unlock();
            }
            _ => {}
        }
    }

    /// Map a touch/click position to a keypad action using the same layout
    /// geometry as render.rs.
    fn handle_touch(&mut self, x: f64, y: f64) {
        let (w, h) = self
            .surfaces
            .first()
            .filter(|s| s.configured)
            .map(|s| (s.width as f64, s.height as f64))
            .unwrap_or((1080.0, 2340.0));

        let scale = w / 1080.0;
        let cx = w / 2.0;
        let btn_r = 36.0 * scale;
        let btn_gap = 28.0 * scale;
        let row_h = btn_r * 2.0 + btn_gap;

        let label_size = 20.0 * scale;
        let dot_r = 6.0 * scale;

        // Reproduce the same Y offsets as render().
        let mut ky = h * 0.14;
        ky += 96.0 * scale * 0.85;           // time
        ky += 22.0 * scale * 2.5;            // date
        ky += label_size * 2.0;              // "Enter Password"
        ky += dot_r * 2.0 + 18.0 * scale;   // dots
        ky += 10.0 * scale;                  // keypad top padding (no error row assumed)

        let cols: [f64; 3] = [
            cx - (btn_r * 2.0 + btn_gap),
            cx,
            cx + (btn_r * 2.0 + btn_gap),
        ];

        let digit_map: [[Option<char>; 3]; 4] = [
            [Some('1'), Some('2'), Some('3')],
            [Some('4'), Some('5'), Some('6')],
            [Some('7'), Some('8'), Some('9')],
            [None,      Some('0'), None],
        ];

        for ri in 0..4 {
            let ry = ky + ri as f64 * row_h;
            for ci in 0..3 {
                let dist = ((x - cols[ci]).powi(2) + (y - ry).powi(2)).sqrt();
                if dist <= btn_r * 1.3 {
                    if let Some(d) = digit_map[ri][ci] {
                        if self.pin.len() < MAX_PIN_DOTS {
                            self.pin.push(d);
                            self.error_msg.clear();
                            self.needs_render = true;
                        }
                        if self.pin.len() == MAX_PIN_DOTS {
                            self.try_unlock();
                        }
                    } else if ri == 3 && ci == 2 {
                        // "Cancel" = backspace
                        if !self.pin.is_empty() {
                            self.pin.pop();
                            self.error_msg.clear();
                            self.needs_render = true;
                        }
                    }
                    return;
                }
            }
        }
    }

    fn try_unlock(&mut self) {
        if auth::check_password(&self.pin) {
            if let Some(lock) = self.lock.take() {
                lock.unlock_and_destroy();
            }
            self.running = false;
        } else {
            self.error_msg = "Wrong PIN".to_string();
            self.pin.clear();
            self.needs_render = true;
        }
    }
}

// ── Wayland Dispatch implementations ──

impl Dispatch<wl_registry::WlRegistry, ()> for LockClient {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_compositor" => {
                    state.compositor =
                        Some(registry.bind::<wl_compositor::WlCompositor, _, _>(name, version.min(6), qh, ()));
                }
                "wl_shm" => {
                    state.shm =
                        Some(registry.bind::<wl_shm::WlShm, _, _>(name, version.min(1), qh, ()));
                }
                "wl_seat" => {
                    state.seat =
                        Some(registry.bind::<wl_seat::WlSeat, _, _>(name, version.min(9), qh, ()));
                }
                "wl_output" => {
                    let output =
                        registry.bind::<wl_output::WlOutput, _, _>(name, version.min(4), qh, ());
                    state.outputs.push(OutputInfo {
                        output,
                        global_name: name,
                    });
                }
                "ext_session_lock_manager_v1" => {
                    state.lock_manager = Some(
                        registry
                            .bind::<ext_session_lock_manager_v1::ExtSessionLockManagerV1, _, _>(
                                name,
                                version.min(1),
                                qh,
                                (),
                            ),
                    );
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_compositor::WlCompositor, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_compositor::WlCompositor, _: wl_compositor::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_shm::WlShm, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_shm_pool::WlShmPool, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_buffer::WlBuffer, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_surface::WlSurface, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_surface::WlSurface, _: wl_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_output::WlOutput, ()> for LockClient {
    fn event(_: &mut Self, _: &wl_output::WlOutput, _: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_seat::WlSeat, ()> for LockClient {
    fn event(
        state: &mut Self,
        seat: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(caps),
        } = event
        {
            if caps.contains(wl_seat::Capability::Keyboard) && state.keyboard.is_none() {
                state.keyboard = Some(seat.get_keyboard(qh, ()));
            }
            if caps.contains(wl_seat::Capability::Touch) && state.touch.is_none() {
                state.touch = Some(seat.get_touch(qh, ()));
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for LockClient {
    fn event(
        state: &mut Self,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let wl_keyboard::Event::Key {
            key, state: key_state, ..
        } = event
        {
            if key_state == WEnum::Value(wl_keyboard::KeyState::Pressed) {
                state.handle_key_press(key);
            }
        }
    }
}

impl Dispatch<wl_touch::WlTouch, ()> for LockClient {
    fn event(
        state: &mut Self,
        _: &wl_touch::WlTouch,
        event: wl_touch::Event,
        _: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            wl_touch::Event::Down { x, y, .. } => {
                state.touch_x = x;
                state.touch_y = y;
            }
            wl_touch::Event::Up { .. } => {
                state.handle_touch(state.touch_x, state.touch_y);
            }
            _ => {}
        }
    }
}

impl Dispatch<ext_session_lock_manager_v1::ExtSessionLockManagerV1, ()> for LockClient {
    fn event(_: &mut Self, _: &ext_session_lock_manager_v1::ExtSessionLockManagerV1, _: ext_session_lock_manager_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<ext_session_lock_v1::ExtSessionLockV1, ()> for LockClient {
    fn event(
        state: &mut Self,
        _lock: &ext_session_lock_v1::ExtSessionLockV1,
        event: ext_session_lock_v1::Event,
        _: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_session_lock_v1::Event::Locked => {
                state.locked = true;
                state.create_lock_surfaces(qh);
            }
            ext_session_lock_v1::Event::Finished => {
                state.running = false;
            }
            _ => {}
        }
    }
}

impl Dispatch<ext_session_lock_surface_v1::ExtSessionLockSurfaceV1, usize> for LockClient {
    fn event(
        state: &mut Self,
        lock_surface: &ext_session_lock_surface_v1::ExtSessionLockSurfaceV1,
        event: ext_session_lock_surface_v1::Event,
        idx: &usize,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let ext_session_lock_surface_v1::Event::Configure {
            serial,
            width,
            height,
        } = event
        {
            lock_surface.ack_configure(serial);
            if let Some(surf) = state.surfaces.get_mut(*idx) {
                surf.width = width;
                surf.height = height;
                surf.configured = true;
            }
            state.render_surface(*idx, qh);
        }
    }
}

// ── Public entry point ──

pub fn run_lock() -> Result<(), Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let display = conn.display();

    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();

    let mut state = LockClient::new();

    display.get_registry(&qh, ());
    event_queue.roundtrip(&mut state)?;

    if state.lock_manager.is_none() {
        return Err("Compositor does not support ext-session-lock-v1".into());
    }
    if state.outputs.is_empty() {
        return Err("No outputs detected".into());
    }

    let lock = state
        .lock_manager
        .as_ref()
        .unwrap()
        .lock(&qh, ());
    state.lock = Some(lock);

    event_queue.roundtrip(&mut state)?;

    if !state.locked {
        return Err("Failed to acquire session lock".into());
    }

    while state.running {
        event_queue.blocking_dispatch(&mut state)?;
        if state.needs_render {
            state.render_all(&qh);
            state.needs_render = false;
        }
    }

    Ok(())
}
