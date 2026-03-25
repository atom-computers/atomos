# Autostart example (Rust / GTK companion)

Per [`docs/PHOSH.md`](../../../docs/PHOSH.md) §1, keep **phoc + phosh** as the session spine and ship new UI as separate binaries. A common integration path is an **XDG autostart** desktop entry under `/etc/xdg/autostart/`.

## On the device

1. Install your binary (or ship it in a custom APK).
2. Install a `.desktop` file with `Hidden=false` and a real `Exec=` line.

## In this repo

`atomos-companion.desktop.example` is a **disabled** template (`Hidden=true`). Copy it into your overlay or pmaports package as `atomos-companion.desktop` and adjust `Exec` / `Name` when you have a real companion app.

Do not commit a live autostart that points at missing binaries: users would get session warnings or failed launches.
