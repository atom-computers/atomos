#!/usr/bin/env bash
# Build atomos-home inside an Alpine arm64 container.
#
# Why: macOS hosts cannot satisfy the GTK4 / wayland pkg-config queries the
# gtk-rs + gtk4-layer-shell sys crates issue when targeting
# `aarch64-unknown-linux-musl` directly. This script runs cargo *inside* an
# Alpine arm64 container where pkg-config is native.
#
# Output:
#   $ROOT_DIR/rust/atomos-home/target/release/atomos-home
# (an aarch64 musl ELF). This path is the second candidate that
# scripts/home-surface/install-atomos-home.sh resolve_bin_path() checks.
#
# Overrides (env):
#   ATOMOS_HOME_BUILD_ENGINE          docker | podman (auto-detected)
#   ATOMOS_HOME_BUILD_CONTAINER_IMAGE base image (default alpine:edge)
#   ATOMOS_HOME_CARGO_CACHE_VOLUME    cargo cache volume name
#   ATOMOS_HOME_CARGO_CACHE_CLEAN     set to 1 to wipe the volume
#   ATOMOS_HOME_BUILD_PLATFORM        force --platform value
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_TOP="$(cd "$ROOT_DIR/.." && pwd)"
ALPINE_IMAGE="${ATOMOS_HOME_BUILD_CONTAINER_IMAGE:-alpine:edge}"
CARGO_CACHE_VOLUME="${ATOMOS_HOME_CARGO_CACHE_VOLUME:-atomos-home-cargo-cache}"

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

ENGINE="${ATOMOS_HOME_BUILD_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if ! ENGINE="$(find_engine)"; then
        echo "ERROR: docker or podman is required for the containerized build." >&2
        echo "  Install one and retry, or set ATOMOS_HOME_BUILD_ENGINE." >&2
        exit 2
    fi
fi

if [ "${ATOMOS_HOME_CARGO_CACHE_CLEAN:-0}" = "1" ]; then
    echo "build-atomos-home-in-container: wiping cargo cache volume '$CARGO_CACHE_VOLUME'"
    "$ENGINE" volume rm -f "$CARGO_CACHE_VOLUME" >/dev/null 2>&1 || true
fi
"$ENGINE" volume create "$CARGO_CACHE_VOLUME" >/dev/null

PLATFORM_FLAG=()
PLATFORM_DESC="native"
if [ -n "${ATOMOS_HOME_BUILD_PLATFORM:-}" ]; then
    PLATFORM_FLAG=(--platform "$ATOMOS_HOME_BUILD_PLATFORM")
    PLATFORM_DESC="$ATOMOS_HOME_BUILD_PLATFORM (override)"
else
    host_arch="$(uname -m)"
    case "$host_arch" in
        aarch64|arm64) : ;;
        *)
            PLATFORM_FLAG=(--platform linux/arm64)
            PLATFORM_DESC="linux/arm64 (auto, host=$host_arch)"
            ;;
    esac
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cat <<EOF
build-atomos-home-in-container:
  engine        : $ENGINE
  image         : $ALPINE_IMAGE
  platform      : $PLATFORM_DESC
  cargo cache   : volume:$CARGO_CACHE_VOLUME
  workspace     : $REPO_TOP -> /work
  output target : /work/iso-postmarketos/rust/atomos-home/target/release/atomos-home

  First run can take 5-15 min under arm64 emulation. Subsequent runs reuse
  \$CARGO_HOME=/cargo from the volume.
EOF

"$ENGINE" run --rm -i \
    ${PLATFORM_FLAG[@]+"${PLATFORM_FLAG[@]}"} \
    -v "$REPO_TOP:/work" \
    -v "$CARGO_CACHE_VOLUME:/cargo" \
    -e CARGO_HOME=/cargo \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -w /work/iso-postmarketos/rust/atomos-home \
    "$ALPINE_IMAGE" /bin/sh -eu <<'SHELL'
set -eu

cat > /etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
https://dl-cdn.alpinelinux.org/alpine/edge/testing
REPOS

echo "[container] apk update + install build deps ..."
apk update >/dev/null
apk add --no-interactive \
    build-base pkgconf \
    rust cargo \
    glib-dev gtk4.0-dev libadwaita-dev \
    cairo-dev pango-dev gdk-pixbuf-dev graphene-dev \
    wayland-dev libxkbcommon-dev >/dev/null

apk add --no-interactive gtk4-layer-shell-dev >/dev/null 2>&1 \
    || apk add --no-interactive gtk4-layer-shell >/dev/null 2>&1 \
    || echo "[container] WARN: gtk4-layer-shell-dev unavailable; build will likely fail at link time"

echo "[container] cargo build atomos-home (release) ..."
cargo build \
    --manifest-path app-gtk/Cargo.toml \
    --release \
    --bin atomos-home

if [ ! -x target/release/atomos-home ]; then
    echo "[container] ERROR: build completed but binary missing at target/release/atomos-home" >&2
    exit 1
fi

echo "[container] built: target/release/atomos-home"
file target/release/atomos-home || true
ls -lh target/release/atomos-home

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] && [ "$HOST_UID" != "0" ]; then
    chown -R "$HOST_UID:$HOST_GID" target /cargo 2>/dev/null || true
fi
SHELL

BIN_PATH="$ROOT_DIR/rust/atomos-home/target/release/atomos-home"
if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: container build returned 0 but no binary at $BIN_PATH" >&2
    exit 1
fi

echo "build-atomos-home-in-container: done."
echo "  binary: $BIN_PATH"