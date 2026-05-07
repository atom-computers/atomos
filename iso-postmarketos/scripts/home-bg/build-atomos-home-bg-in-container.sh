#!/usr/bin/env bash
# Build atomos-home-bg inside an Alpine arm64 container.
#
# Why: macOS hosts cannot satisfy the GTK4/cairo/glib pkg-config queries
# that the gtk-rs crates issue when targeting `aarch64-unknown-linux-musl`
# directly — the system pkg-config has no way to find a Linux sysroot.
# This script sidesteps the problem by running cargo *inside* an Alpine
# arm64 container where pkg-config is native and the Alpine
# `gtk4.0-dev` / `webkit2gtk-6.0-dev` / `gtk4-layer-shell-dev` packages
# satisfy every dep the rust crates ask for. Same approach
# `scripts/build-qemu.sh` uses; this is the home-bg-only slice of it,
# extracted so the hotfix workflow doesn't need to spin up the full
# image build pipeline.
#
# Output: $ROOT_DIR/rust/atomos-home-bg/target/release/atomos-home-bg
# (an aarch64 musl ELF). This path is the second candidate that
# `scripts/home-bg/install-atomos-home-bg.sh` and
# `scripts/home-bg/hotfix-home-bg.sh` `resolve_bin_path()` checks, so
# subsequent installs/hotfixes pick it up automatically without needing
# the env override.
#
# Performance notes:
#   - First run on macOS x86_64 host is slow (5-15 min) because Alpine
#     arm64 runs under QEMU emulation, and apk install + first cargo
#     build both happen from scratch.
#   - Subsequent runs reuse the cargo registry/build cache stored in a
#     named container volume (`atomos-home-bg-cargo-cache`). Set
#     ATOMOS_HOME_BG_CARGO_CACHE_CLEAN=1 to wipe.
#   - On Apple Silicon (arm64 host) the container runs natively, much
#     faster.
#
# Overrides (env):
#   ATOMOS_HOME_BG_BUILD_ENGINE         docker | podman (auto-detected)
#   ATOMOS_HOME_BG_BUILD_CONTAINER_IMAGE  base image (default alpine:edge)
#   ATOMOS_HOME_BG_CARGO_CACHE_VOLUME   cargo cache volume name
#   ATOMOS_HOME_BG_CARGO_CACHE_CLEAN    set to 1 to wipe the volume
#   ATOMOS_HOME_BG_BUILD_PLATFORM       force --platform value (e.g. linux/arm64)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_TOP="$(cd "$ROOT_DIR/.." && pwd)"
ALPINE_IMAGE="${ATOMOS_HOME_BG_BUILD_CONTAINER_IMAGE:-alpine:edge}"
CARGO_CACHE_VOLUME="${ATOMOS_HOME_BG_CARGO_CACHE_VOLUME:-atomos-home-bg-cargo-cache}"

find_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
        return 0
    fi
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
        return 0
    fi
    return 1
}

ENGINE="${ATOMOS_HOME_BG_BUILD_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if ! ENGINE="$(find_engine)"; then
        echo "ERROR: docker or podman is required for the containerized build." >&2
        echo "  Install one and retry, or set ATOMOS_HOME_BG_BUILD_ENGINE." >&2
        exit 2
    fi
fi

if [ "${ATOMOS_HOME_BG_CARGO_CACHE_CLEAN:-0}" = "1" ]; then
    echo "build-atomos-home-bg-in-container: wiping cargo cache volume '$CARGO_CACHE_VOLUME'"
    "$ENGINE" volume rm -f "$CARGO_CACHE_VOLUME" >/dev/null 2>&1 || true
fi
"$ENGINE" volume create "$CARGO_CACHE_VOLUME" >/dev/null

PLATFORM_FLAG=()
PLATFORM_DESC="native"
if [ -n "${ATOMOS_HOME_BG_BUILD_PLATFORM:-}" ]; then
    PLATFORM_FLAG=(--platform "$ATOMOS_HOME_BG_BUILD_PLATFORM")
    PLATFORM_DESC="$ATOMOS_HOME_BG_BUILD_PLATFORM (override)"
else
    host_arch="$(uname -m)"
    case "$host_arch" in
        aarch64|arm64)
            : # native arm64 host — let the runtime pick the matching image
            ;;
        *)
            # x86_64 / other host: force linux/arm64 so the produced ELF
            # actually runs on the target device's aarch64 musl userspace.
            PLATFORM_FLAG=(--platform linux/arm64)
            PLATFORM_DESC="linux/arm64 (auto, host=$host_arch)"
            ;;
    esac
fi

# pmbootstrap-style cache friendliness: surface UID/GID so files written
# back into the workspace aren't owned by root on Linux hosts. (No-op on
# macOS docker desktops because the file owner is normalized at the
# bind-mount layer.)
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cat <<EOF
build-atomos-home-bg-in-container:
  engine        : $ENGINE
  image         : $ALPINE_IMAGE
  platform      : $PLATFORM_DESC
  cargo cache   : volume:$CARGO_CACHE_VOLUME
  workspace     : $REPO_TOP -> /work
  output target : /work/iso-postmarketos/rust/atomos-home-bg/target/release/atomos-home-bg

  First run can take 5-15 min under arm64 emulation (apk install + cold
  cargo build). Subsequent runs reuse \$CARGO_HOME=/cargo from the volume.
EOF

# Heredoc runs as root inside the container; chown step at the end
# normalizes ownership of files written into the bind-mounted workspace.
"$ENGINE" run --rm -i \
    "${PLATFORM_FLAG[@]}" \
    -v "$REPO_TOP:/work" \
    -v "$CARGO_CACHE_VOLUME:/cargo" \
    -e CARGO_HOME=/cargo \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -w /work/iso-postmarketos/rust/atomos-home-bg \
    "$ALPINE_IMAGE" /bin/sh -eu <<'SHELL'
set -eu

# Mirror the repo set build-qemu's home-bg build container uses so we
# pull from edge/main + edge/community + edge/testing. gtk4-layer-shell
# lives in edge/testing only.
cat > /etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
https://dl-cdn.alpinelinux.org/alpine/edge/testing
REPOS

echo "[container] apk update + install build deps ..."
apk update >/dev/null
# Identical package set to scripts/build-qemu.sh's heavy build container
# (intersected to what atomos-home-bg-app actually needs). The wider
# *-dev packages (cairo, pango, etc.) are pulled in transitively by
# gtk4.0-dev / webkit2gtk-6.0-dev's pkg-config Requires:, but listing
# them explicitly survives any future trimming of those metapackages.
apk add --no-interactive \
    build-base pkgconf \
    rust cargo \
    glib-dev gtk4.0-dev \
    webkit2gtk-6.0-dev \
    cairo-dev pango-dev gdk-pixbuf-dev graphene-dev \
    wayland-dev libxkbcommon-dev >/dev/null

# gtk4-layer-shell ships in edge/testing; some Alpine mirrors rotate
# slowly. Try -dev first, fall back to runtime, fall back to nothing.
apk add --no-interactive gtk4-layer-shell-dev >/dev/null 2>&1 \
    || apk add --no-interactive gtk4-layer-shell >/dev/null 2>&1 \
    || echo "[container] WARN: gtk4-layer-shell-dev unavailable; build will likely fail at link time"

echo "[container] cargo build atomos-home-bg (release) ..."
cargo build \
    --manifest-path app-gtk/Cargo.toml \
    --release \
    --bin atomos-home-bg

if [ ! -x target/release/atomos-home-bg ]; then
    echo "[container] ERROR: build completed but binary missing at target/release/atomos-home-bg" >&2
    exit 1
fi

echo "[container] built: target/release/atomos-home-bg"
file target/release/atomos-home-bg || true
ls -lh target/release/atomos-home-bg

# Normalize ownership of any new files cargo wrote into the workspace
# bind mount so a follow-up `git status` on the host isn't littered
# with root-owned files. macOS docker shares already remap ownership;
# this only matters on Linux hosts.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] && [ "$HOST_UID" != "0" ]; then
    chown -R "$HOST_UID:$HOST_GID" target /cargo 2>/dev/null || true
fi
SHELL

BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/release/atomos-home-bg"
if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: container build returned 0 but no binary at $BIN_PATH" >&2
    exit 1
fi

echo "build-atomos-home-bg-in-container: done."
echo "  binary: $BIN_PATH"
