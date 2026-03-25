# Local Phosh source

Upstream shell: [World/Phosh/phosh](https://gitlab.gnome.org/World/Phosh/phosh).

The working tree lives in **`phosh/`** next to this file. That directory is listed in `.gitignore` so this repository does not embed Phosh history or a submodule pointer—clone it on demand like any other local directory.

Populate or update (AtomOS patches apply automatically; patches are always applied by checkout-phosh.sh):

```bash
bash ../../scripts/phosh/checkout-phosh.sh
# re-apply patches only:
bash ../../scripts/phosh/apply-phosh-atomos-patches.sh
```

`checkout-phosh.sh` resets local uncommitted changes before applying patches so stale states do not break `make build`.

See [`docs/PHOSH.md`](../../docs/PHOSH.md), [`packaging/README.md`](packaging/README.md), and [`autostart-example/README.md`](autostart-example/README.md).
