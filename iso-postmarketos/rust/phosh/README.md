# AtomOS Phosh fork (short-term shell)

Upstream: [World/Phosh/phosh](https://gitlab.gnome.org/World/Phosh/phosh).

This directory holds the **local AtomOS Phosh fork checkout** at **`phosh/`** (listed in [`.gitignore`](.gitignore)). The clone is **not** a git submodule: you edit files directly in that git repo and maintain your own branch history there.

Populate or update:

```bash
cd iso-postmarketos
bash scripts/phosh/checkout-phosh.sh
```

Quick UI preview (egui, fast feedback loop):

```bash
bash scripts/phosh/preview-phosh-gtk-container.sh
# Linux only (container + X11 forwarding):
bash scripts/phosh/preview-phosh-gtk-container.sh --container-x11
```

Override the clone location (e.g. temporary checkout):

- `ATOMOS_PHOSH_SRC=/path/to/phosh` — used by `checkout-phosh.sh` and `build-atomos-phosh-pmbootstrap.sh`.
- `PHOSH_CLONE_DIR=/path/to/phosh` — overrides `ATOMOS_PHOSH_SRC` when set (usually only for scripting).

Pin upstream on checkout:

- `ATOMOS_PHOSH_GIT_REF=<tag-or-commit>`

Legacy layout: an old clone under `vendor/phosh/phosh` is ignored by default; remove it or point `ATOMOS_PHOSH_SRC` at it until you migrate.

Packaging notes: [`../../vendor/phosh/packaging/README.md`](../../vendor/phosh/packaging/README.md). Autostart examples: [`../../vendor/phosh/autostart-example/`](../../vendor/phosh/autostart-example/). Full shell doc: [`../../docs/PHOSH.md`](../../docs/PHOSH.md).
