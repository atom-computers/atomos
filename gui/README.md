# gui

Atom OS graphical shell — ported from `iso-postmarketos/rust/`, stripped of Linux
dependencies (GTK4, Wayland, D-Bus, Cairo, Pango) and retargeted to the custom
`kernel/` + `render/` stack.

## Directory Structure

```
gui/
├── gtk-shim/                    # Translation layer: GTK4/Cairo API → render/ matrix ops
├── atomos-theme/                # Shared drawing primitives (ported to render/)
├── atomos-lockscreen/           # Lock screen (app-gtk/ → gtk-shim)
├── atomos-top-bar/              # Status bar (core/ + app-gtk/ → gtk-shim)
├── atomos-quick-settings/       # Quick settings panel (app-gtk/ → gtk-shim)
├── atomos-home/                 # Home surface (core/ + app-gtk/ → gtk-shim)
├── atomos-home-bg/              # Wallpaper (core/ + app-gtk/ → gtk-shim)
├── atomos-overview-chat-ui/     # Chat input overlay (core/ + app-gtk/ → gtk-shim)
├── atomos-app-handler/          # App launcher & switcher (core/ + app-gtk/ → gtk-shim)
├── atomos-lifecycle/            # Process orchestration daemon (zero changes needed)
├── atomos-preview/              # Evolves into the system compositor
└── atomos-comp/                 # Reference compositor (eventually replaced)
```

## Architecture

Each crate follows a **core/app** split:

| Layer | Purpose | Dependencies |
|---|---|---|
| `core/` | Pure logic: state machines, layout math, IPC protocols, event handling | None (pure Rust) |
| `app-gtk/` | Production UI: GTK4 widgets, Cairo drawing, layer-shell positioning | **Swapped from `gtk4-rs` → `gtk-shim`** |

The `core/` crates need **zero changes** — they contain no rendering or platform code.
The `app-gtk/` crates swap their dependency from real `gtk4-rs` / `cairo-rs` to
`gtk-shim`, which provides the same API surface backed by `render/` matrix operations.

## gtk-shim — Translation Layer

Instead of rewriting each app's UI from scratch, `gtk-shim` translates the subset of
GTK4/Cairo API calls our apps actually use into matrix operations on `Spatial` regions.

```
┌─────────────────────────────────────────────────┐
│  atomos-lockscreen/app-gtk/                     │
│  atomos-top-bar/app-gtk/                        │
│  atomos-home/app-gtk/          ← unchanged code │
│  ...                                            │
└────────────┬────────────────────────────────────┘
             │ use gtk::Window, cairo::Context::rectangle, ...
             ▼
┌─────────────────────────────────────────────────┐
│  gtk-shim                                       │
│                                                 │
│  widget.rs   gtk::Window → Spatial region      │
│  draw.rs     cairo::rectangle → render quad    │
│  text.rs     pango layout → glyph atlas        │
│  layout.rs   gtk::Box → spatial positioning    │
│  input.rs    GDK event → kernel input region    │
└────────────┬────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────┐
│  render/           math.rs, rasterize.rs        │
│  kernel/           Kernel trait, RegionId       │
└─────────────────────────────────────────────────┘
```

### Translation mapping

| GTK4 / Cairo call | Translates to |
|---|---|
| `gtk::Application::new(id, flags)` | Register process with kernel, open input regions |
| `gtk::Window::new()` + `present()` | `kernel.create_region(Spatial {...}, ...)` |
| `cairo::Context::rectangle(x, y, w, h)` | 4 vertices → `Mat4::translate` → queue rasterize op |
| `cairo::Context::set_source_rgba(r,g,b,a)` | Set element values for subsequent fill |
| `cairo::Context::fill()` | `rasterize::rasterize()` → write to window's `Spatial` region |
| `cairo::Context::paint()` | Same as fill but writes reflection values |
| `pango::Layout::new()` + `.set_text()` | Create glyph atlas entries, track text bounding box |
| `pango::Layout::show(cairo)` | Rasterize glyph quads into window region |
| `gtk::Box::pack_start(child, expand, fill)` | Compute child model matrix offset from box constraints |
| `gtk::Label::new(text)` | Pango layout + show, cached until text changes |
| `gtk::Button::new()` + `.connect_clicked()` | Render rounded rect + label, read touch input for hit test |
| `gtk::Entry::new()` + `.buffer()` | Render text field, read keyboard input region, update buffer |
| `connect_key_press_event()` | Subscribe to keyboard `Spatial` region changes |
| `connect_motion_notify_event()` | Subscribe to touch `Spatial` region changes |

## Porting an App — Step by Step

1. **Move the crate** into `gui/` from `iso-postmarketos/rust/`
2. **Change dependency** in `app-gtk/Cargo.toml`:
   ```diff
   - gtk4 = { version = "0.10", package = "gtk4" }
   + gtk-shim = { path = "../../gtk-shim" }
   ```
3. **Update imports** in `app-gtk/src/`:
   ```diff
   - use gtk::prelude::*;
   + use gtk_shim::prelude::*;
   ```
4. **Remove Linux-only dependencies**: `gtk4-layer-shell`, `libadwaita`, `webkit6`, D-Bus
5. **Replace Wayland layer-shell** with `Spatial` region positioning:
   ```diff
   - gtk4_layer_shell::init_for_window(&window);
   - window.set_anchor(Edge::Bottom, true);
   + // Window is now a Spatial region; position via compositor z-order
   ```
6. **Test on mock kernel**: run the `app-gtk` binary with `kernel-mock` and `gtk-shim`
   backing on the host machine before targeting bare metal.

## App-Specific Notes

### atomos-lockscreen
- **Complexity**: Low — single surface, clock text + swipe indicator
- **First to port**: minimal GTK4 API surface, good `gtk-shim` integration test

### atomos-top-bar
- **Complexity**: Low — 24px or 32px horizontal bar anchored to top edge
- `core/` provides battery/signal state via D-Bus → replace with kernel region reads
- egui version (`app-egui/`) serves as layout reference

### atomos-quick-settings
- **Complexity**: Medium — toggle buttons, sliders, translucent overlay
- Heavy `cairo` usage for custom drawing → exercise for `gtk-shim` draw module

### atomos-home
- **Complexity**: High — bottom bar (15px), home bar with app grid, chat entry
- `core/` contains pure logic; `app-gtk/` uses `gtk4-layer-shell` for positioning

### atomos-home-bg
- **Complexity**: Medium — currently uses WebKitGTK for WebGL wallpaper
- WebKitGTK is dropped entirely. Replace with a `render/`-based animated background
  or a `Spatial` region stream of pre-rendered frames.

### atomos-overview-chat-ui
- **Complexity**: Medium — multi-line text input (1–6 lines), Enter to submit
- `core/` has all logic (`line_count`, `layout_state_for_text`, `enter_action`)
- `app-gtk/` uses `gtk4-layer-shell` → replace with `Spatial` region positioning

### atomos-app-handler
- **Complexity**: High — swipe gesture tracking, app launcher, toplevel management
- `core/` has `handle_drag_progress`, `evaluate_swipe_up`, `evaluate_card_dismiss`
- Replaces `wlr-foreign-toplevel-management` Wayland protocol with kernel process tracking
- Replaces `gtk4-layer-shell` with `Spatial` region positioning

### atomos-lifecycle
- **Changes needed**: None. Pure logic — reads lock/drag state, decides layer targets,
  spawns/restarts processes. Works identically on the new kernel.

### atomos-preview
- Evolves into the **system compositor** (see Phase 6 of TASKLIST.md)
- Spawns each app as a child process with its own `Spatial` output region
- Composites app regions by z-order into the display region
- Routes input from hardware `Spatial` regions to the correct app

### atomos-comp
- **Reference only**. The Smithay-based Wayland compositor is replaced by the
  `atomos-preview` compositor on the new kernel.
