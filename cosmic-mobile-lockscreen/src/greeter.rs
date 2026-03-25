use std::os::unix::io::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use wayland_client::protocol::{
    wl_buffer, wl_callback, wl_compositor, wl_keyboard, wl_output, wl_registry, wl_seat, wl_shm,
    wl_shm_pool, wl_surface, wl_touch,
};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum};
use wayland_protocols::xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base};

use crate::greetd;
use crate::render::{Renderer, MAX_PIN_DOTS};

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
    fn new(shm: &wl_shm::WlShm, qh: &QueueHandle<GreeterClient>, w: u32, h: u32) -> Self {
        let stride = w * 4;
        let size = (stride * h) as usize;
        let fd = create_shm_fd();
        unsafe { libc::ftruncate(fd.as_fd().as_raw_fd(), size as libc::off_t) };
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(), size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED, fd.as_fd().as_raw_fd(), 0,
            )
        };
        assert_ne!(ptr, libc::MAP_FAILED);
        let pool = shm.create_pool(fd.as_fd(), size as i32, qh, ());
        let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, wl_shm::Format::Argb8888, qh, ());
        Self { _pool: pool, buffer, _fd: fd, ptr: ptr as *mut u8, len: size }
    }
    fn write(&self, data: &[u8]) {
        assert!(data.len() <= self.len);
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), self.ptr, data.len()) };
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) { unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) }; }
}

fn create_shm_fd() -> OwnedFd {
    #[cfg(target_os = "linux")]
    {
        let name = c"atomos-greeter";
        let fd = unsafe { libc::memfd_create(name.as_ptr(), 1) };
        assert!(fd >= 0, "memfd_create failed");
        return unsafe { OwnedFd::from_raw_fd(fd) };
    }
    #[cfg(not(target_os = "linux"))]
    {
        use std::os::unix::io::IntoRawFd;
        let path = std::env::temp_dir().join(format!("atomos-greeter-{}", std::process::id()));
        let f = std::fs::OpenOptions::new()
            .read(true).write(true).create(true).truncate(true)
            .open(&path).expect("tmpfile for shm");
        let _ = std::fs::remove_file(&path);
        unsafe { OwnedFd::from_raw_fd(f.into_raw_fd()) }
    }
}

pub struct GreeterClient {
    running: bool,
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    seat: Option<wl_seat::WlSeat>,
    wm_base: Option<xdg_wm_base::XdgWmBase>,
    #[allow(dead_code)]
    keyboard: Option<wl_keyboard::WlKeyboard>,
    #[allow(dead_code)]
    touch: Option<wl_touch::WlTouch>,

    surface: Option<wl_surface::WlSurface>,
    #[allow(dead_code)]
    xdg_surface: Option<xdg_surface::XdgSurface>,
    #[allow(dead_code)]
    toplevel: Option<xdg_toplevel::XdgToplevel>,
    width: u32,
    height: u32,
    configured: bool,
    buffer: Option<ShmBuffer>,

    pin: String,
    error_msg: String,
    needs_render: bool,
    renderer: Renderer,
    touch_x: f64,
    touch_y: f64,
}

impl GreeterClient {
    fn new() -> Self {
        Self {
            running: true,
            compositor: None, shm: None, seat: None, wm_base: None,
            keyboard: None, touch: None,
            surface: None, xdg_surface: None, toplevel: None,
            width: 0, height: 0, configured: false, buffer: None,
            pin: String::new(), error_msg: String::new(),
            needs_render: false, renderer: Renderer::new(),
            touch_x: 0.0, touch_y: 0.0,
        }
    }

    fn setup_surface(&mut self, qh: &QueueHandle<Self>) {
        let compositor = self.compositor.as_ref().expect("no compositor");
        let wm_base = self.wm_base.as_ref().expect("no xdg_wm_base");
        let surface = compositor.create_surface(qh, ());
        let xdg_surface = wm_base.get_xdg_surface(&surface, qh, ());
        let toplevel = xdg_surface.get_toplevel(qh, ());
        toplevel.set_title("AtomOS".to_string());
        toplevel.set_fullscreen(None);
        surface.commit();
        self.surface = Some(surface);
        self.xdg_surface = Some(xdg_surface);
        self.toplevel = Some(toplevel);
    }

    fn render(&mut self, qh: &QueueHandle<Self>) {
        if !self.configured || self.width == 0 || self.height == 0 {
            return;
        }
        let data = self.renderer.render(self.width, self.height, self.pin.len(), &self.error_msg);
        let shm = self.shm.as_ref().expect("no shm");
        let buf = ShmBuffer::new(shm, qh, self.width, self.height);
        buf.write(&data);
        let surface = self.surface.as_ref().expect("no surface");
        surface.attach(Some(&buf.buffer), 0, 0);
        surface.damage_buffer(0, 0, self.width as i32, self.height as i32);
        surface.commit();
        self.buffer = Some(buf);
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
                self.try_login();
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
            KEY_ENTER | KEY_KP_ENTER => self.try_login(),
            _ => {}
        }
    }

    fn handle_touch(&mut self, x: f64, y: f64) {
        let (w, h) = if self.configured && self.width > 0 {
            (self.width as f64, self.height as f64)
        } else {
            (1080.0, 2340.0)
        };
        let scale = w / 1080.0;
        let cx = w / 2.0;
        let btn_r = 36.0 * scale;
        let btn_gap = 28.0 * scale;
        let row_h = btn_r * 2.0 + btn_gap;
        let label_size = 20.0 * scale;
        let dot_r = 6.0 * scale;

        let mut ky = h * 0.14;
        ky += 96.0 * scale * 0.85;
        ky += 22.0 * scale * 2.5;
        ky += label_size * 2.0;
        ky += dot_r * 2.0 + 18.0 * scale;
        ky += 10.0 * scale;

        let cols: [f64; 3] = [cx - (btn_r * 2.0 + btn_gap), cx, cx + (btn_r * 2.0 + btn_gap)];
        let digit_map: [[Option<char>; 3]; 4] = [
            [Some('1'), Some('2'), Some('3')],
            [Some('4'), Some('5'), Some('6')],
            [Some('7'), Some('8'), Some('9')],
            [None, Some('0'), None],
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
                        if self.pin.len() == MAX_PIN_DOTS { self.try_login(); }
                    } else if ri == 3 && ci == 2 {
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

    fn try_login(&mut self) {
        match greetd::authenticate_and_start_session(&self.pin) {
            Ok(true) => {
                eprintln!("cosmic-greeter: login successful, session starting");
                self.running = false;
            }
            Ok(false) => {
                self.error_msg = "Wrong PIN".to_string();
                self.pin.clear();
                self.needs_render = true;
            }
            Err(e) => {
                eprintln!("cosmic-greeter: greetd error: {e}");
                self.error_msg = "Login error".to_string();
                self.pin.clear();
                self.needs_render = true;
            }
        }
    }
}

// ── Wayland Dispatch implementations ──

impl Dispatch<wl_registry::WlRegistry, ()> for GreeterClient {
    fn event(state: &mut Self, registry: &wl_registry::WlRegistry, event: wl_registry::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_compositor" => { state.compositor = Some(registry.bind::<wl_compositor::WlCompositor, _, _>(name, version.min(6), qh, ())); }
                "wl_shm" => { state.shm = Some(registry.bind::<wl_shm::WlShm, _, _>(name, version.min(1), qh, ())); }
                "wl_seat" => { state.seat = Some(registry.bind::<wl_seat::WlSeat, _, _>(name, version.min(9), qh, ())); }
                "xdg_wm_base" => { state.wm_base = Some(registry.bind::<xdg_wm_base::XdgWmBase, _, _>(name, version.min(1), qh, ())); }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_compositor::WlCompositor, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_compositor::WlCompositor, _: wl_compositor::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_shm::WlShm, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_shm_pool::WlShmPool, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_buffer::WlBuffer, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_surface::WlSurface, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_surface::WlSurface, _: wl_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_output::WlOutput, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_output::WlOutput, _: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }
impl Dispatch<wl_callback::WlCallback, ()> for GreeterClient { fn event(_: &mut Self, _: &wl_callback::WlCallback, _: wl_callback::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {} }

impl Dispatch<wl_seat::WlSeat, ()> for GreeterClient {
    fn event(state: &mut Self, seat: &wl_seat::WlSeat, event: wl_seat::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wl_seat::Event::Capabilities { capabilities: WEnum::Value(caps) } = event {
            if caps.contains(wl_seat::Capability::Keyboard) && state.keyboard.is_none() {
                state.keyboard = Some(seat.get_keyboard(qh, ()));
            }
            if caps.contains(wl_seat::Capability::Touch) && state.touch.is_none() {
                state.touch = Some(seat.get_touch(qh, ()));
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for GreeterClient {
    fn event(state: &mut Self, _: &wl_keyboard::WlKeyboard, event: wl_keyboard::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_keyboard::Event::Key { key, state: key_state, .. } = event {
            if key_state == WEnum::Value(wl_keyboard::KeyState::Pressed) {
                state.handle_key_press(key);
            }
        }
    }
}

impl Dispatch<wl_touch::WlTouch, ()> for GreeterClient {
    fn event(state: &mut Self, _: &wl_touch::WlTouch, event: wl_touch::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wl_touch::Event::Down { x, y, .. } => { state.touch_x = x; state.touch_y = y; }
            wl_touch::Event::Up { .. } => { state.handle_touch(state.touch_x, state.touch_y); }
            _ => {}
        }
    }
}

impl Dispatch<xdg_wm_base::XdgWmBase, ()> for GreeterClient {
    fn event(_: &mut Self, wm_base: &xdg_wm_base::XdgWmBase, event: xdg_wm_base::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            wm_base.pong(serial);
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for GreeterClient {
    fn event(state: &mut Self, xdg_surface: &xdg_surface::XdgSurface, event: xdg_surface::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let xdg_surface::Event::Configure { serial } = event {
            xdg_surface.ack_configure(serial);
            if !state.configured {
                state.configured = true;
                if state.width == 0 { state.width = 1080; }
                if state.height == 0 { state.height = 2340; }
                state.render(qh);
            }
        }
    }
}

impl Dispatch<xdg_toplevel::XdgToplevel, ()> for GreeterClient {
    fn event(state: &mut Self, _: &xdg_toplevel::XdgToplevel, event: xdg_toplevel::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            xdg_toplevel::Event::Configure { width, height, .. } => {
                if width > 0 { state.width = width as u32; }
                if height > 0 { state.height = height as u32; }
            }
            xdg_toplevel::Event::Close => { state.running = false; }
            _ => {}
        }
    }
}

// ── Public entry point ──

pub fn run_greeter() -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("cosmic-greeter: entering greeter mode (login screen)");

    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();
    let mut state = GreeterClient::new();

    display.get_registry(&qh, ());
    event_queue.roundtrip(&mut state)?;

    if state.wm_base.is_none() {
        return Err("Compositor does not support xdg_wm_base".into());
    }

    state.setup_surface(&qh);
    event_queue.roundtrip(&mut state)?;

    while state.running {
        event_queue.blocking_dispatch(&mut state)?;
        if state.needs_render {
            state.render(&qh);
            state.needs_render = false;
        }
    }

    Ok(())
}
