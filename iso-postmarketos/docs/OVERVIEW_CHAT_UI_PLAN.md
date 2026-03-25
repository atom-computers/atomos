# Overview Chat UI Migration Plan

This task list replaces the Phosh overview bottom search entry with a Rust chat UI
surface while keeping the existing submit helper path during rollout.

## Phase 1: split patch responsibilities

1. Keep one patch focused on overview behavior:
   - hide app grid/search results in overview
   - keep the layout shell without coupling to text submit logic
2. Move entry-submit behavior to a second patch:
   - message entry visuals and Enter behavior
   - `/usr/libexec/atomos-overview-chat-submit` call path
3. Validate patch order remains deterministic via filename sort in
   `scripts/phosh/apply-phosh-atomos-patches.sh`.

## Phase 2: add Rust chat UI skeleton

1. Add workspace `rust/atomos-overview-chat-ui` (`core/` library + `app-gtk/` + `app-egui/`) with:
   - `gtk4` + `libadwaita` UI app entrypoint
   - multiline `TextView` input
   - growing input height until 6 lines, then vertical scroll
2. Keep backend contract stable:
   - Enter (without Shift) submits to `atomos-overview-chat-submit`
   - Shift+Enter inserts newline
3. Apply transparent root window styling and full-width bottom input container.

## Phase 3: runtime wiring

1. Install binary and helper launcher into rootfs overlay.
2. Add a launcher shim in `/usr/libexec` that starts the Rust binary if present.
3. Keep logging fallback if binary is absent to avoid hard-failing overview.

## Phase 4: replace legacy search-entry flow

1. Remove legacy overview bottom `GtkSearchEntry` behavior from patch set.
2. Trigger show/hide of Rust overlay from Phosh overview lifecycle hooks.
3. Validate focus and keyboard behavior with squeekboard on device.

## Validation checklist

- Input box is full width in portrait and landscape.
- Input grows from 1 to 6 lines, then scrolls vertically.
- Enter submits; Shift+Enter inserts newline.
- Transparent background preserves wallpaper visibility.
- Closing overview dismisses chat UI cleanly.
