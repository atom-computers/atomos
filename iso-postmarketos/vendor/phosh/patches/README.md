# AtomOS Phosh patches

Patches apply on top of a plain clone of [World/Phosh/phosh](https://gitlab.gnome.org/World/Phosh/phosh) (see [`../README.md`](../README.md)).

| Patch | Purpose |
|-------|---------|
| `0001-atomos-overview-no-app-grid.patch` | §2 in [`docs/PHOSH.md`](../../../docs/PHOSH.md): hide overview app/favorites search results so the shell stops surfacing app grid content. |
| `0002-atomos-overview-chat-entry-submit.patch` | Transitional bottom **Message…** search-entry UI; **Enter** spawns **`/usr/libexec/atomos-overview-chat-submit`** (from the mobile overlay). This is intended to be removed once the Rust chat UI is lifecycle-wired. |
| `0003-atomos-overview-chat-ui-lifecycle.patch` | Bridge to Rust UI: trigger `/usr/libexec/atomos-overview-chat-ui --show/--hide` from app-grid lifecycle and hide the transitional in-Phosh search entry. |

Apply manually (from `iso-postmarketos/`):

```bash
bash scripts/phosh/apply-phosh-atomos-patches.sh
```

**`make build`** runs this via **`scripts/phosh/checkout-phosh.sh`** automatically.

After rebasing Phosh, refresh a patch with:

```bash
cd vendor/phosh/phosh
# edit, then:
git diff src/... > ../patches/NNNN-short-name.patch
```
