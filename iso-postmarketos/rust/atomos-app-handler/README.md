# atomos-app-switcher

Rust port of the AtomOS app switcher overlay. Replaces the C `PhoshOverview`
+ `atomos-swipe-bridge` round trip with a single GTK4 layer-shell binary that:

- captures the bottom-edge upward drag itself (no unix-socket round trip to
  Phosh),
- presents a full-screen `Layer::Overlay` switcher surface painted opaque
  `#0a0a0a` (matching [`atomos-home-bg`'s `HOME_BG_BASE_COLOR`](../atomos-home-bg/app-egui/src/main.rs))
  so the running app is fully occluded behind the switcher rather than
  showing through,
- lists, activates and closes running toplevels via the Wayland
  `wlr-foreign-toplevel-management-unstable-v1` protocol on a side thread,
- supports per-card swipe-away to close.

## Workspace layout

```
atomos-app-switcher/
  core/      pure logic (no GTK, no Wayland) — tests run on macOS
  app-egui/  eframe dev preview with mock toplevels
  app-gtk/   Linux device binary: GTK4 + layer-shell + Wayland client thread
```

## Local dev loop

Logic-only (any host):

```bash
cargo test -p atomos-app-switcher
```

Combined preview (any host):

```bash
bash scripts/app-switcher/preview-app-switcher-egui.sh
```

Real surface (Linux + Wayland compositor with wlr-layer-shell + wlr-foreign-toplevel-management):

```bash
bash scripts/app-switcher/preview-app-switcher.sh
```

Device diagnosis — when the swipe-up does not open the switcher on a
running QEMU/FP4 image, run the diagnose script. It SSHes to the device
and prints one `PASS`/`FAIL`/`INFO` line per link in the pipeline (binary
installed, autostart wiring, phosh env, runtime libs, process up, launcher
log, compositor globals) so the highest `FAIL` line is the closest to the
root cause. Exports `ATOMOS_APP_SWITCHER_DEBUG_TINT=1` on the device first
to make the otherwise-invisible bottom-edge handle a translucent red:

```bash
bash scripts/app-switcher/diagnose-app-switcher.sh config/arm64-virt.env user@localhost
# QEMU image: ATOMOS_DEVICE_SSH_PORT=2222 bash scripts/app-switcher/diagnose-app-switcher.sh config/arm64-virt.env user@localhost
```

Debug knobs (only set when investigating, never in production):

| Env var                              | Default | Meaning                                                                 |
|--------------------------------------|---------|-------------------------------------------------------------------------|
| `ATOMOS_APP_SWITCHER_DEBUG_TINT`     | `0`     | Paint the bottom-edge handle a translucent red so it is visible.        |

## Phosh-side yield contract

The rust handle and Phosh's draggable layer-surface compete for the same
bottom-edge touch region. Phosh yields the edge when its environment has
both keys set at session start:

```sh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1   # phosh-home drag_mode = NONE
ATOMOS_APP_SWITCHER_TAKES_OVER=1          # PhoshOverview hidden
```

`phosh-session.in` (from the AtomOS Phosh fork at
[`rust/phosh/phosh/data/phosh-session.in`](../phosh/phosh/data/phosh-session.in))
sources `/etc/atomos/phosh-profile.env` before exec-ing `phoc` + `gnome-session`,
so the keys reach Phosh iff that file exists in the rootfs with the right values.

Who writes the file, per build path:

| Build path                       | Writer                                                                    |
|----------------------------------|---------------------------------------------------------------------------|
| `scripts/build-image.sh` (pmbootstrap) | `scripts/rootfs/apply-overlay.sh` (wholesale heredoc — full template) |
| `scripts/build-qemu.sh`          | `scripts/app-switcher/install-app-switcher.sh` (append-if-missing)        |
| `scripts/build-fairphone4*.sh`   | `scripts/app-switcher/install-app-switcher.sh` (append-if-missing)        |

The two writers compose: `apply-overlay`'s wholesale rewrite still includes
the same keys with the same values; `install-app-switcher`'s append is a
no-op when the keys are already present. The final-verify steps in
`build-qemu.sh` / `_lib-verify.sh` assert both keys land regardless of path.

If the swipe works in the egui preview but not on the device, the very
first thing `diagnose-app-switcher.sh` checks is the live phosh process's
`/proc/<pid>/environ` — a missing `ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1`
there means phosh-home is still owning the bottom edge and our handle's
`GestureDrag` never fires.

## Runtime contracts

Constants in [`core/src/lib.rs`](core/src/lib.rs) are the source of truth:

- `LAYER_SHELL_NAMESPACE = "atomos-app-switcher"`
- `ENABLE_RUNTIME_ENV = "ATOMOS_APP_SWITCHER_ENABLE_RUNTIME"`
- `RUNTIME_FILE_BASENAME = "atomos-app-switcher"`
- `BACKDROP_BASE_COLOR_HEX = "#0a0a0a"` (visual parity with home-bg)

Env knobs (with defaults):

| Env var                                      | Default | Meaning                                                  |
|----------------------------------------------|---------|----------------------------------------------------------|
| `ATOMOS_APP_SWITCHER_ENABLE_RUNTIME`         | `0`     | Master runtime gate (launcher exits if not `1`).         |
| `ATOMOS_APP_SWITCHER_HANDLE_HEIGHT`          | `24`    | Bottom-edge swipe-handle strip height in px.             |
| `ATOMOS_APP_SWITCHER_OPEN_THRESHOLD_PX`      | `48`    | Minimum upward delta to trigger overlay open.            |
| `ATOMOS_APP_SWITCHER_DISMISS_THRESHOLD_PX`   | `120`   | Minimum vertical card delta to trigger card close.       |

Build + install/hotfix/diagnose helpers:

- `scripts/app-switcher/build-app-switcher.sh`
- `scripts/app-switcher/install-app-switcher.sh`
- `scripts/app-switcher/hotfix-app-switcher.sh`
- `scripts/app-switcher/diagnose-app-switcher.sh`
