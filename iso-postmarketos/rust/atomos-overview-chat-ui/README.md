# atomos-overview-chat-ui

Workspace under this directory (no Cargo feature flags):

- **`core/`** — library crate `atomos-overview-chat-ui` (shared input logic; **`cargo test` here runs without GTK**).
- **`app-gtk/`** — crate `atomos-overview-chat-ui-app`, production binary **`atomos-overview-chat-ui`** (GTK/libadwaita only; used by `make build` cross-builds).
- **`app-egui/`** — crate `atomos-overview-chat-ui-egui`, dev binary **`atomos-overview-chat-ui-dev`** (eframe/egui for desktop preview where GTK is unavailable or for quick logic checks).

Starter Rust UI binary for the Phosh overview chat surface.

Current scope:

- transparent application window root (chat container is translucent)
- full-width bottom input area
- multiline `TextView` growth from 1 to 6 lines
- vertical scrolling after 6 lines
- Enter submits to `/usr/libexec/atomos-overview-chat-submit`
- Shift+Enter inserts a newline

This crate is intentionally decoupled from the existing Phosh C patch until
overview lifecycle hooks are added for show/hide.

## Production build (Linux/Phosh)

From `rust/atomos-overview-chat-ui/`:

- `cargo build -p atomos-overview-chat-ui-app --release --bin atomos-overview-chat-ui`

## Local preview (no flash)

**Full stack (recommended on Linux):** the production binary uses GTK4 and
libadwaita — the same GNOME stack Phosh builds on. Run it inside a normal
desktop session (Wayland or X11) so you get real theming and widgets:

- from `iso-postmarketos/`: `bash scripts/overview-chat-ui/preview-overview-chat-ui.sh`

The app picks **desktop-like** vs **phone overlay** mode automatically from GDK
monitor size (logical pixels): large screens get a taller window, visible root
background, title bar, and input outline; narrow phone-sized monitors keep the
short transparent strip used on-device.

**`cargo run -p atomos-overview-chat-ui-app --bin atomos-overview-chat-ui`** on a
large monitor uses the same detection (no env vars). **`make build` / `build-overview-chat-ui.sh`** invoke `cargo build -p atomos-overview-chat-ui-app` for you.

This does **not** embed the full Phosh shell (panels, overview chrome, phoc).
For that, use a Linux VM/device with the full image build flow.

**macOS / quick logic-only:** the egui dev preview shares input behavior but is
not libadwaita (`-p atomos-overview-chat-ui-egui`):

- `bash scripts/overview-chat-ui/preview-overview-chat-ui-egui.sh`
- or `ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui bash scripts/overview-chat-ui/preview-overview-chat-ui.sh`

On Linux you can force egui with `ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui`.

## Device hotfix loop

For device-side iteration without reflashing the full image:

- from `iso-postmarketos/`: `bash scripts/overview-chat-ui/hotfix-overview-chat-ui.sh config/fairphone-fp4.env pmos@<device-host>`

`build-overview-chat-ui.sh` finds the pmbootstrap rootfs sysroot by trying, in order: `PMB_WORK_OVERRIDE`, `PMB_WORK` from the profile env, then `$HOME/.atomos-pmbootstrap-work/<PROFILE_NAME>` (the same default `scripts/build-image.sh` uses). You need an existing `chroot_rootfs_<PROFILE_NAME>` there—e.g. after `make build` or `pmb install`.

This rebuilds the current binary, uploads it and the `/usr/libexec` launcher
helpers, and restarts the overview UI process on the device. Override
`ATOMOS_OVERVIEW_CHAT_UI_RESTART_CMD` if you want to bounce the full shell
session instead of just the chat UI process.

## Tests

Run the library tests (no GTK required):

- `cargo test -p atomos-overview-chat-ui`

The suite covers:

- line counting and growth clamping behavior
- scrollbar threshold behavior
- Enter vs Shift+Enter submit behavior
- lifecycle argument parsing used by launcher wrappers
