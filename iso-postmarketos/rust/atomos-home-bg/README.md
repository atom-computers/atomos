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
  **`atomos-home-bg-combined-preview`** (eframe). Renders the white
  canvas + bouncing ball animation in one eframe window with an
  overview-chat-ui input strip overlaid on top. Cross-platform visual
  parity check for macOS / dep-light Linux boxes where WebKitGTK can't
  run. Ball physics + HSL helpers are extracted into pure functions so
  the animation is unit-testable without opening a window.

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
  layering in a single window with the same white canvas + bouncing
  ball under a chat input strip.

## Production build

```
bash scripts/home-bg/build-atomos-home-bg.sh config/<profile>.env
bash scripts/home-bg/install-atomos-home-bg.sh config/<profile>.env
```

`build-image.sh` invokes both automatically when `BUILD_HOME_BG=1`
(default). Disable with `make build without-home-bg` or
`bash scripts/build-image.sh --without-home-bg`.

## Environment variables

| Var | Default | Purpose |
| --- | --- | --- |
| `ATOMOS_HOME_BG_ENABLE_RUNTIME` | `0` in rootfs, `1` in preview | Runtime gate. When `0` the binary exits without presenting anything. |
| `ATOMOS_HOME_BG_URL` | `file:///usr/share/atomos-home-bg/index.html` | URL the webview loads. `file`/`http`/`https` accepted. |
| `ATOMOS_HOME_BG_LAYER` | `bottom` | `background` / `bottom` / `top` / `overlay`. Default is `bottom` so the webview sits above the session wallpaper. |
| `ATOMOS_HOME_BG_INTERACTIVE` | `0` | Must be literal `1` to enable input. |
| `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` | `1` in launcher | pmOS minimal images lack bubblewrap. |
| `WEBKIT_DISABLE_DMABUF_RENDERER` | `1` in launcher | Some phone GBM nodes pick wrong device. |

## Shipping a React app

The image ships a placeholder `index.html`. Drop a React build into
`/usr/share/atomos-home-bg/` (keep `index.html` at the root) or override
the URL via `ATOMOS_HOME_BG_URL=file:///opt/my-react-build/index.html`.
