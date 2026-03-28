# atomos-overview-chat-ui

Workspace under this directory (no Cargo feature flags):

- **`core/`** — library crate `atomos-overview-chat-ui` (shared input logic; **`cargo test` here runs without GTK**).
- **`app-gtk/`** — crate `atomos-overview-chat-ui-app`, production binary **`atomos-overview-chat-ui`** (GTK/libadwaita only; used by `make build` cross-builds).
- **`app-egui/`** — crate `atomos-overview-chat-ui-egui`, dev binary **`atomos-overview-chat-ui-dev`** (eframe/egui for desktop preview where GTK is unavailable or for quick logic checks).

Starter Rust UI binary for the Phosh overview chat surface.

Current scope:

- transparent application window root (chat container is translucent)
- full-width bottom input area
- top-left dock-style app-grid icon button
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

App-grid button behavior is command-based so device images can choose the launcher
mechanism. Override with:

- `ATOMOS_OVERVIEW_CHAT_UI_APP_GRID_CMD='<your launcher command>'`

**macOS / quick logic-only:** the egui dev preview shares input behavior but is
not libadwaita (`-p atomos-overview-chat-ui-egui`):

- `bash scripts/overview-chat-ui/preview-overview-chat-ui-egui.sh`
- or `ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui bash scripts/overview-chat-ui/preview-overview-chat-ui.sh`

On Linux you can force egui with `ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui`.

## Device hotfix loop

For device-side iteration without reflashing the full image:

- from `iso-postmarketos/`: `bash scripts/overview-chat-ui/hotfix-overview-chat-ui.sh config/fairphone-fp4.env pmos@<device-host>`
- password auth without SSH keys: hotfix uses `sshpass -p` directly. Password priority is `ATOMOS_DEVICE_SSHPASS`, then `SSHPASS`, then `PMOS_INSTALL_PASSWORD`, then hardcoded fallback `147147`.
- remote `sudo` now uses the same password by default (`ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO_PASSWORD`, defaulting to SSH password). Override sudo command with `ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO` or disable it with an empty value. Use your actual password value (do not literally pass `your-sudo-password`).
- if your local machine has no pmbootstrap rootfs sysroot yet, deploy an existing binary without rebuilding:
  `ATOMOS_OVERVIEW_CHAT_UI_SKIP_BUILD=1 ATOMOS_OVERVIEW_CHAT_UI_BIN=rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui bash scripts/overview-chat-ui/hotfix-overview-chat-ui.sh config/fairphone-fp4.env user@172.16.42.1`
- if that local binary is incompatible (glibc-linked), deploy **launcher/scripts only** while keeping the device binary:
  `ATOMOS_OVERVIEW_CHAT_UI_SKIP_BIN_INSTALL=1 bash scripts/overview-chat-ui/hotfix-overview-chat-ui.sh config/fairphone-fp4.env user@172.16.42.1`
- default behavior now auto-falls back to launcher-only if cross-build fails (e.g. missing pmbootstrap sysroot). Disable fallback with `ATOMOS_OVERVIEW_CHAT_UI_FALLBACK_LAUNCHER_ONLY_ON_BUILD_FAIL=0`.

`build-overview-chat-ui.sh` finds the pmbootstrap rootfs sysroot by trying, in order: `PMB_WORK_OVERRIDE`, `PMB_WORK` from the profile env, then `$HOME/.atomos-pmbootstrap-work/<PROFILE_NAME>` (the same default `scripts/build-image.sh` uses). You need an existing `chroot_rootfs_<PROFILE_NAME>` there—e.g. after `make build` or `pmb install`.

This rebuilds the current binary, uploads it and the `/usr/libexec` launcher
helpers, and restarts the overview UI process on the device. Override
`ATOMOS_OVERVIEW_CHAT_UI_RESTART_CMD` if you want to bounce the full shell
session instead of just the chat UI process.

**`--show` over SSH:** SSH sessions usually have no `WAYLAND_DISPLAY`, so GTK exits at once (empty `ps`). Use **`pgrep phosh | head -n 1`** (not `pgrep -x phosh` — on some images it matches nothing and leaves `PID` empty). On-device one-liner:

```sh
PID="$(pgrep phosh | head -n 1)"; [ -n "$PID" ] || exit 1
for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY; do
  line="$(tr '\0' '\n' < "/proc/$PID/environ" | grep "^${v}=" || true)"
  [ -n "$line" ] && export "$line"
done
/usr/libexec/atomos-overview-chat-ui --show
```

From your **Mac/Linux builder** (password only in your shell env, never committed):

```sh
cd iso-postmarketos
export ATOMOS_DEVICE_SSHPASS='…'
bash scripts/device/atomos-device-ssh.sh
bash scripts/device/atomos-overview-chat-ui-remote-show.sh
bash scripts/device/atomos-overview-chat-ui-remote-fg.sh
bash scripts/device/atomos-overview-chat-ui-remote-diag.sh
```

The launcher appends GTK output to `$XDG_RUNTIME_DIR/atomos-overview-chat-ui.log` and logs a journal hint if the process dies within ~0.2s (`journalctl -t atomos-overview-chat-ui`).

## Tests

Run the library tests (no GTK required):

- `cargo test -p atomos-overview-chat-ui`

The suite covers:

- line counting and growth clamping behavior
- scrollbar threshold behavior
- Enter vs Shift+Enter submit behavior
- lifecycle argument parsing used by launcher wrappers
