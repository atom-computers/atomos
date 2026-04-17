# Phosh extras (packaging & examples)

The **AtomOS Phosh fork** (clone + direct-edit workflow) lives under **[`../../rust/phosh/`](../../rust/phosh/)** — not a submodule; the upstream clone under `rust/phosh/phosh/` is gitignored.

This `vendor/phosh/` tree keeps **packaging** and **autostart** material that is not part of the C sources:

- [`packaging/README.md`](packaging/README.md) — pmaports / APK repo workflow
- [`autostart-example/`](autostart-example/) — desktop file template for companion UI

Refresh Phosh sources from `iso-postmarketos/`:

```bash
bash scripts/phosh/checkout-phosh.sh
```
