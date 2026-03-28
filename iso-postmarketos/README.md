# AtomOS postmarketOS Image Scaffold

This directory builds one AtomOS mobile image target: `fairphone-fp4` with Phosh.

## Build

Run exactly one command from `iso-postmarketos/`:

- `make build`

The build script is fixed-path and does not require feature flags or extra env vars.
It configures pmbootstrap, builds patched Phosh, applies AtomOS rootfs customizations,
and exports host-safe image files.

Output artifacts:

- `build/host-export-fairphone-fp4/boot.img`
- `build/host-export-fairphone-fp4/fairphone-fp4.img`

The flashed rootfs includes **`btlescan`** as `/usr/bin/btlescan` (and `/usr/local/bin/btlescan`) after a successful `make build`.

## Host Requirements

- Linux host or Linux VM (required for pmbootstrap loop-device image creation)
- `python3` and `git` on the host
- For the Rust overview UI: **`cargo`** on the `PATH` (e.g. rustup), **or** Docker/Podman (same fallback as `install-btlescan.sh`)

If `pmbootstrap` is missing, the build flow installs it via
`scripts/pmb/ensure-pmbootstrap.sh`.

## Flashing

Example fastboot flow:

- `fastboot flash boot build/host-export-fairphone-fp4/boot.img`
- flash the exported `fairphone-fp4.img` with your preferred FP4 image workflow
- `fastboot reboot`

## Validation (Optional)

After a successful build:

- `bash scripts/validate/validate-lock-parity.sh config/fairphone-fp4.env`
- `python3 -m pytest tests/test_lock_parity_scripts.py`

## Troubleshooting

- `so:libsimdutf.so.31` / `vte3-gtk4` during install:
  verify mirrors via `pmbootstrap config mirrors.alpine` and re-run `make build`.
- `Transport endpoint is not connected` on VM shared folders:
  move the checkout to local VM disk and run `make build` there.
- **`mkfs.ext4` fails on `/dev/installp2` during `pmbootstrap install`:**
  usually a **stale loop mount** from an earlier run or a **bad backing filesystem** for `~/.atomos-pmbootstrap-work/`.
  `make build` runs `pmbootstrap shutdown` immediately before install to clear old chroots/loops; if it still fails, run
  `pmbootstrap -w ~/.atomos-pmbootstrap-work/fairphone-fp4 shutdown` yourself, then `make build` again.
  If the work dir lives on **virtiofs / 9p / NFS / FUSE** (typical shared VM folders), move it to **local ext4** inside the VM
  (or ensure the VM home disk is not a host share).   Check the line above `^^^` in
  `~/.atomos-pmbootstrap-work/fairphone-fp4/log.txt` for the exact `mkfs.ext4` message, and confirm **enough free disk space**
  for the device image (several GB).
- **`abuild`: "No private key found" / `abuild-keygen` during vendor Phosh build:**
  `make build` runs `abuild-keygen -a -n` inside the **native** pmbootstrap chroot before `pmbootstrap build phosh`.
  If you still see this after updating, run manually:
  `pmbootstrap -w ~/.atomos-pmbootstrap-work/fairphone-fp4 chroot -- /bin/sh -c 'busybox su pmos -c "HOME=/home/pmos abuild-keygen -a -n"'`
  (from the same user account you use for `make build`), then `make build` again.

## References

- `docs/PHOSH.md`
- `docs/OVERVIEW_CHAT_UI_PLAN.md`
