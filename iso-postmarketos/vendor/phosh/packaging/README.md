# Packaging a patched Phosh for postmarketOS

Use a **local clone** of upstream ([`../../rust/phosh/README.md`](../../rust/phosh/README.md), `bash scripts/phosh/checkout-phosh.sh`) and ship `.apk` files that override pmaports builds. Maintain your shell changes directly in `rust/phosh/phosh` and package from that tree.

## pmaports / `abuild`

1. Copy the `main/phosh` (and any deps you change, e.g. `phoc`) APKBUILD from [pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) into a fork or overlay tree.
2. Point the `source=` line at a tarball you generate from your clone (`git archive`, `meson dist`, or a fixed commit URL), or use a `file://` path only on your build machine while iterating.
3. Bump `pkgrel` (or `pkgver`) and add `replaces="phosh"` / version constraints if you need your package to win over the official repo.
4. Build with `pmbootstrap chroot -r` / `abuild -r` per upstream docs, then publish the resulting packages to a **static APK repository** (index + `.apk` files).

## Wiring the image

Set in `config/<profile>.env`:

- `PMOS_CUSTOM_APK_REPO_URLS` — comma-separated repository base URLs (same format as lines in `/etc/apk/repositories`).
- `PMOS_CUSTOM_APK_KEY_FILES` — comma-separated paths to `.pub` keys, relative to `iso-postmarketos/` or absolute.
- `PMOS_CUSTOM_APK_PACKAGES` — optional comma-separated package names to `apk add` after the repo is wired during **`make build`**.

[`scripts/rootfs/wire-custom-apk-repos.sh`](../../../scripts/rootfs/wire-custom-apk-repos.sh) runs automatically during `make build` when these variables are set.

## Extra packages from pmaports

Add official package names to **`PMOS_EXTRA_PACKAGES`** in the same profile env file so they are pulled during `pmbootstrap install`.
