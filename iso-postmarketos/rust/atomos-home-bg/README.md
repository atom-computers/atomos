# atomos-home-bg

Non-interactable web-view surface that sits on the Phosh home screen
**behind** the overview/lock/app chrome. Use it to render a React (or any
static-HTML) "wallpaper" that can update itself while never stealing
pointer/touch focus from the shell.

## Workspace

- **`core/`** — crate `atomos-home-bg` (pure logic; `cargo test` runs on any
  host including macOS, no GTK deps).
- **`app-gtk/`** — crate `atomos-home-bg-app`, production binary
  **`atomos-home-bg`** (Linux only: GTK4 + `gtk4-layer-shell` +
  `webkit2gtk-6.0`). Non-Linux hosts compile a stub so the workspace still
  builds / `cargo check`s.
- **`app-egui/`** — crate `atomos-home-bg-egui`, dev-only binary
  **`atomos-home-bg-combined-preview`** (eframe). Renders an opaque
  `#0a0a0a` home-bg base in one eframe window with an
  overview-chat-ui input strip overlaid on top. Cross-platform visual
  parity check for macOS / dep-light Linux boxes where WebKitGTK can't
  run. egui can't execute the WebGL shader the device runs, so this
  preview only mirrors the base color — exercise the chat-strip
  layering / interactivity here, and use the layered (WebKitGTK) mode
  on a real Linux+Wayland host if you need to see the shader.

## Tests

**Home-bg only:**

```
bash scripts/home-bg/test-atomos-home-bg-local.sh
```

**Combined stack with `atomos-overview-chat-ui`:**

```
bash scripts/home-bg/test-home-bg-and-overview-chat-ui.sh
```

The combined-stack integration test (`tests/combined_with_overview_chat_ui.rs`)
asserts the two crates can coexist layered:

- distinct `wlr-layer-shell` namespaces;
- home-bg's default layer (`Background`) has a strictly lower z-index
  than overview-chat-ui's default layer (`Top`);
- distinct runtime-enable env vars + distinct pidfile/log basenames;
- home-bg stays `NonInteractive` by default so pointer/touch reaches
  overview-chat-ui's chat input;
- symmetric `--show`/`--hide` lifecycle arg parsing.

## Local preview

**Layered (auto-selects on host capabilities):**

```
bash scripts/home-bg/preview-home-bg-and-overview-chat-ui.sh
```

- `layered` — Linux + Wayland + `wlr-layer-shell` + WebKitGTK 6 + GTK4 +
  libadwaita: launches the real two-process composition.
- `egui-fallback` — macOS or Linux missing the deps: runs
  `atomos-home-bg-combined-preview` (eframe) which simulates the
  layering in a single window with the same `#0a0a0a` base color under
  a chat input strip. The WebGL event-horizon shader does not run in
  this mode (egui has no WebKit); use `layered` mode if you need to
  see the shader.

## Production build

```
bash scripts/home-bg/build-atomos-home-bg.sh config/<profile>.env
bash scripts/home-bg/install-atomos-home-bg.sh config/<profile>.env
```

`build-image.sh` invokes both automatically when `BUILD_HOME_BG=1`
(default). Disable with `make build without-home-bg` or
`bash scripts/build-image.sh --without-home-bg`.

### Building from a non-Linux host (macOS, etc.)

The host cross-compile path (`cargo build --target
aarch64-unknown-linux-musl`) needs a working pkg-config that can
resolve `gtk4` / `webkit2gtk-6.0` / `gtk4-layer-shell` for that target,
which macOS pkg-config can't do without a Linux sysroot. Both
`build-atomos-home-bg.sh` and `scripts/home-bg/hotfix-home-bg.sh`
auto-detect non-Linux hosts and delegate to
`scripts/home-bg/build-atomos-home-bg-in-container.sh`, which runs
`cargo` inside an Alpine arm64 container where pkg-config is native.

```
# explicit invocation:
bash scripts/home-bg/build-atomos-home-bg-in-container.sh

# or just run the hotfix with CONTENT_ONLY=0; it'll pick the
# container path automatically when run from macOS:
ATOMOS_HOME_BG_CONTENT_ONLY=0 \
    ATOMOS_HOME_BG_REMOTE_SUDO_PASSWORD='…' \
    bash scripts/home-bg/hotfix-home-bg.sh config/<profile>.env user@host:port
```

Requirements:

- `docker` or `podman` available on the host (auto-detected; override
  with `ATOMOS_HOME_BG_BUILD_ENGINE=docker|podman`).
- On x86_64 hosts (Intel Mac, x86_64 Linux) the script forces
  `--platform linux/arm64`, so the runtime needs binfmt/QEMU emulation.
  Docker Desktop / Colima / OrbStack ship this. Apple Silicon hosts
  run the container natively (much faster).

First run takes 5-15 min on x86_64 (Alpine arm64 emulation + apk
install + cold cargo build). Subsequent runs reuse the cargo
registry/build cache stored in a named volume
(`atomos-home-bg-cargo-cache`). Wipe with
`ATOMOS_HOME_BG_CARGO_CACHE_CLEAN=1`.

Force the path explicitly with `ATOMOS_HOME_BG_BUILD_MODE=host` or
`ATOMOS_HOME_BG_BUILD_MODE=container`.

## Environment variables

| Var | Default | Purpose |
| --- | --- | --- |
| `ATOMOS_HOME_BG_ENABLE_RUNTIME` | `0` in rootfs, `1` in preview | Runtime gate. When `0` the binary exits without presenting anything. |
| `ATOMOS_HOME_BG_URL` | `file:///usr/share/atomos-home-bg/index.html` | URL the webview loads. `file`/`http`/`https` accepted. |
| `ATOMOS_HOME_BG_LAYER` | `bottom` | `background` / `bottom` / `top` / `overlay`. Default is `bottom` so the webview sits above the session wallpaper. |
| `ATOMOS_HOME_BG_INTERACTIVE` | `0` | Must be literal `1` to enable input. |
| `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` | `1` in launcher | pmOS minimal images lack bubblewrap. |
| `WEBKIT_DISABLE_DMABUF_RENDERER` | `1` in launcher | Some phone GBM nodes pick wrong device. |

## Shipped placeholder content

The image ships a WebGL **event-horizon** background — a black-hole /
accretion-disk shader on a `#0a0a0a` opaque base. Three files in
`data/atomos-home-bg/` make this up:

| file | role |
| --- | --- |
| `index.html` | Entry point WebKit loads. Sets the `#0a0a0a` body background, hosts `<canvas id="event-horizon">`, and `<script src="event-horizon.js">`. |
| `event-horizon.tsx` | **Canonical React source.** Standalone client component (`"use client"`, `useEffect`-based WebGL setup) suitable for bundling into Next.js / Vite consumers. |
| `event-horizon.js` | Vanilla JS port of the same shader. Hand-derived from the .tsx so the rootfs WebKitGTK can load it without a Node bundler at boot. **Keep in lock-step with the .tsx** — `core/tests/placeholder_content_shape.rs` cross-checks the uniform set, default parameter values, and runtime message API. |

The shader caps `devicePixelRatio` at 1.5 to keep the 200-iteration
ray-march tractable on phone GPUs. WebGL failure is non-fatal: the
script bails cleanly and the dark `#0a0a0a` base from CSS stays
painted.

External callers can tweak shader parameters at runtime by posting
`{ type: "param", name, value }` messages to the webview's `window`
(supported `name`s: `ROTATION_SPEED`, `DISK_INTENSITY`, `STARS_ONLY`,
`TILT`, `ROTATE`, `BH_CENTER_X`, `BH_CENTER_Y`, `BH_SCALE`,
`CHROMATIC`).

### Shipping a different React app

Drop your React build into `/usr/share/atomos-home-bg/` (keep
`index.html` at the root) or override the URL via
`ATOMOS_HOME_BG_URL=file:///opt/my-react-build/index.html`.

### WebGL on minimal images

The `/usr/libexec/atomos-home-bg` launcher defaults to
`LIBGL_ALWAYS_SOFTWARE=1` and `GSK_RENDERER=cairo` because the
WebKitGTK GL stack can crash early on QEMU. The event-horizon shader
will still render via software GL (slowly). On a real device with
working hardware GL, set `ATOMOS_HOME_BG_LIBGL_ALWAYS_SOFTWARE=0` (and
optionally `ATOMOS_HOME_BG_GSK_RENDERER=gl`) to enable hardware
rendering.

`atomos-home-bg-app` also configures the WebView at startup with:

- `enable-webgl=true` (explicit — guards against future webkit2gtk
  defaults flipping it off)
- `hardware-acceleration-policy=ALWAYS` (without this, webkit2gtk's
  on-demand heuristic refuses GL on software-only stacks like QEMU
  virt and silently disables WebGL)
- `enable-write-console-messages-to-stdout=true` (forwards the JS
  `console.log` / `console.warn` / `console.error` from
  `event-horizon.js` into `$XDG_RUNTIME_DIR/atomos-home-bg.log`)
- `enable-developer-extras=true` (lets you attach the WebKit remote
  inspector on device by setting `WEBKIT_INSPECTOR_SERVER=ip:port`)

### Diagnosing a "plain dark background" on device

If after deploying you only see the `#0a0a0a` base color and not the
shader animation, walk this checklist:

1. **Look at the screen.** `event-horizon.js` paints a small
   diagnostic banner in the bottom-left corner of the WebView whenever
   any failure path fires (canvas missing, WebGL refused, shader
   compile/link error). Read what it says.
2. **Look at the launcher log.** `cat $XDG_RUNTIME_DIR/atomos-home-bg.log`
   on device. The Rust binary logs the effective WebKit settings line
   `webkit settings: webgl=… hw-accel=… console-to-stdout=…` once per
   start. The same log captures every JS `console.warn` / `console.error`
   call from the script, so you'll see e.g.
   `event-horizon: WebGL unavailable — getContext('webgl') returned null`
   inline.
3. **Look at the launcher journal.** `journalctl -t atomos-home-bg`.
   Each `--show` invocation logs the GL env vars in effect so you can
   tell if some override didn't propagate.
4. **Make sure you actually re-deployed the binary.** The hotfix
   script's default mode is **content-only** — it ships the new
   `index.html` / `event-horizon.js` but leaves the on-device binary
   untouched. The WebKit settings above only take effect after a
   binary redeploy:

   ```
   ATOMOS_HOME_BG_CONTENT_ONLY=0 \
       ATOMOS_HOME_BG_REMOTE_SUDO_PASSWORD='…' \
       bash scripts/home-bg/hotfix-home-bg.sh config/<profile>.env user@host:port
   ```

   Or do a full rebuild via `bash scripts/build-image.sh` /
   `bash scripts/build-qemu.sh`.

Once the device is known healthy and the banner is more annoying than
useful, suppress it with `?diag=0` in the URL (set
`ATOMOS_HOME_BG_URL=file:///usr/share/atomos-home-bg/index.html?diag=0`)
or by adding `data-diag="off"` to the `<html>` element.
