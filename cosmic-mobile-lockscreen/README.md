# cosmic-mobile-lockscreen

Drop-in `cosmic-greeter` replacement for AtomOS with a phone-style PIN
lockscreen designed for Phosh-parity mobile locking under COSMIC.

## Architecture

The binary is named `cosmic-greeter` so it's a direct drop-in for the upstream
package. It operates in two modes based on the running user:

- **Greeter mode** (running as `cosmic-greeter` system user): exec's the
  upstream binary at `/usr/bin/cosmic-greeter.real` for login screen
  functionality.

- **Locker mode** (running as any other user): enters a daemon that watches
  for logind `Lock` and `PrepareForSleep` D-Bus signals. On signal, acquires
  `ext-session-lock-v1` from the compositor and renders a phone-style PIN
  lockscreen with software rendering (tiny-skia). Authenticates via PAM
  (dlopen, no compile-time dependency).

`cosmic-session` calls `start_component("cosmic-greeter")` which launches this
binary directly — no wrapper scripts, no competing lock clients, no XDG
autostart race conditions.

## Commands

- `cargo test`
- `cargo run -- --spec`
- `cargo run -- --render-test`
- `cargo run -- --lock` (one-shot lock for testing)
- `cargo run -- --daemon` (explicit daemon mode)
- `cargo run` (default: daemon mode when run as regular user)

## Design

Phone-style lockscreen with:
- Full-screen wallpaper or sunset gradient background
- Large clock display
- Date
- PIN dot indicators
- Circular numeric keypad (1-9, 0)
- Emergency / Cancel buttons
