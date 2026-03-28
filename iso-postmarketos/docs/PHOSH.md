# Phosh (AtomOS mobile image)

This scaffold builds **`postmarketos-ui-phosh`** (`PMOS_UI=phosh` in [`config/fairphone-fp4.env`](../config/fairphone-fp4.env)). Everything below is **two** workstreams.

---

## 1. Customize Phosh and adopt Rust incrementally

**Goal:** Diverge from vanilla pmaports Phosh when needed, rebase on [World/Phosh](https://gitlab.gnome.org/World/Phosh/), and land **new UI in Rust** without rewriting the whole shell overnight.

**Where Phosh source lives:** Keep a **plain local clone** of upstream Phosh at **`vendor/phosh/phosh`** (gitignored; not a submodule). **`make build`** runs [`scripts/phosh/checkout-phosh.sh`](../scripts/phosh/checkout-phosh.sh) first (clone/update + apply patches). You can refresh manually with `bash scripts/phosh/checkout-phosh.sh`. See [`vendor/phosh/README.md`](../vendor/phosh/README.md).

**Packaging:** Pick one path — pmaports fork, custom APK repo (static HTTP + signing keys), or hybrid (override only `phosh` / `phoc` / `squeekboard`). Fork the APKBUILDs you change; bump versions or `replaces=` so your `.apk` wins. See [`vendor/phosh/packaging/README.md`](../vendor/phosh/packaging/README.md).

**Wire the image:** Set **`PMOS_CUSTOM_APK_REPO_URLS`**, **`PMOS_CUSTOM_APK_KEY_FILES`**, and optionally **`PMOS_CUSTOM_APK_PACKAGES`** in `config/fairphone-fp4.env`; [`scripts/rootfs/wire-custom-apk-repos.sh`](../scripts/rootfs/wire-custom-apk-repos.sh) runs during **`make build`** (full chroot: `apk update` + `apk add`). Add pmaports package names to **`PMOS_EXTRA_PACKAGES`**. Keep `PMOS_UI=phosh` until you ship a replacement UI metapackage.

**Rust / new UI:** Keep **phoc + phosh** as the session spine. Ship new pieces as separate binaries or libs (e.g. GTK4/libadwaita via gtk-rs, or Wayland clients). Integrate via autostart or greetd until you deliberately replace the shell (panel, overview, notifications, session contract). Template: [`vendor/phosh/autostart-example/`](../vendor/phosh/autostart-example/).

**Rebase & security:** Rebase patches on upstream tags; watch pmaports `edge` and CVEs for packages you fork.

**This repo today:** On a **Linux** builder, **`make build`** runs checkout + patches, builds patched Phosh via **[`scripts/phosh/build-atomos-phosh-pmbootstrap.sh`](../scripts/phosh/build-atomos-phosh-pmbootstrap.sh)**, then applies AtomOS rootfs customizations including wallpaper, [`scripts/phosh/apply-atomos-phosh-dconf.sh`](../scripts/phosh/apply-atomos-phosh-dconf.sh), and [`scripts/rootfs/apply-overlay.sh`](../scripts/rootfs/apply-overlay.sh) (includes **`/usr/libexec/atomos-overview-chat-submit`**). Validate with [`scripts/validate/validate-lock-parity.sh`](../scripts/validate/validate-lock-parity.sh).

---

## 2. Overview: bottom chat input, no apps

**Product goal:** The overview should **not** list or search apps. Replace the **app search bar** with a **chat-style input**, **anchored at the bottom** (top panel can stay as today).

**Implementation (AtomOS):** The overview patch chain is now split for migration:
- [`vendor/phosh/patches/0001-atomos-overview-no-app-grid.patch`](../vendor/phosh/patches/0001-atomos-overview-no-app-grid.patch): hides app/favorites overview content.
- [`vendor/phosh/patches/0002-atomos-overview-chat-entry-submit.patch`](../vendor/phosh/patches/0002-atomos-overview-chat-entry-submit.patch): transitional **Message…** bottom entry that submits via **`/usr/libexec/atomos-overview-chat-submit`**.
- [`vendor/phosh/patches/0003-atomos-overview-chat-ui-lifecycle.patch`](../vendor/phosh/patches/0003-atomos-overview-chat-ui-lifecycle.patch): overview lifecycle bridge that toggles **`/usr/libexec/atomos-overview-chat-ui --show/--hide`** and hides the transitional in-Phosh entry.
- [`vendor/phosh/patches/0004-atomos-overview-chat-ui-show-on-unfold.patch`](../vendor/phosh/patches/0004-atomos-overview-chat-ui-show-on-unfold.patch): ensures **`--show`** runs whenever the overview **unfolds** (swipe/Super), not only via the application-view key action (upstream sets `focus_app_search` only there).
- [`vendor/phosh/patches/0005-atomos-transparent-top-panel-and-no-exclusive-zone.patch`](../vendor/phosh/patches/0005-atomos-transparent-top-panel-and-no-exclusive-zone.patch): makes the folded status bar transparent and removes its exclusive zone so wallpaper/content continues behind the panel area.

The long-term target is a Rust UI surface (`rust/atomos-overview-chat-ui`) with transparent background and multiline growth behavior. Patches apply during **`make build`** (via checkout) or manually: **`./scripts/phosh/apply-phosh-atomos-patches.sh`**.

**macOS:** `make build` exits immediately; full image creation requires Linux loop devices. You can still patch/test Phosh changes from a Linux VM/device.

**Upstream map:** In a Phosh checkout, the overview embeds **`PhoshAppGrid`** in `src/ui/app-grid.ui` + `src/app-grid.c`, inside `src/ui/overview.ui` (older notes pointed at `src/search/`; the on-device overview is this app grid).

**What dconf can still do:** Ship **empty favorites** (`favorites "@as []"` on `sm.puri.phosh` and `mobi.phosh.shell` — confirm with `gsettings list-schemas | grep -E 'phosh|puri|mobi'` on device) via `/etc/dconf/db/local.d/51-atomos-phosh-favorites.conf` + `dconf update` in the chroot. Implemented by [`scripts/phosh/apply-atomos-phosh-dconf.sh`](../scripts/phosh/apply-atomos-phosh-dconf.sh) during **`make build`**. That clears the home favorites strip; it does **not** remove overview apps or turn search into chat — that requires the Phosh UI changes above.

**OSK / Squeekboard:** Focus and dismiss behavior between the search entry and **squeekboard** is coordinated upstream. Odd keyboard focus issues are fixed in **Phosh** and/or **Squeekboard**, not in `iso-postmarketos` scripts.
