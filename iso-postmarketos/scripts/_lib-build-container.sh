# shellcheck shell=bash
# scripts/_lib-build-container.sh -- thin wrapper that runs the heavy
# compile container body. The body itself lives in a real shell file
# (_lib-build-container-body.sh) so it is shellcheck-able and easier
# to diff than a multi-thousand-character single-quoted heredoc.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME REPO_TOP
# MESON_CACHE_MOUNT PMOS_KEY_HOST PMOS_REPO_URL USE_VENDOR_PHOSH
# BUILD_HOME_BG BUILD_APP_HANDLER

atomos_build_heavy_components() {
    echo "=== build-fairphone4-v2: build vendor phosh + Rust components ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        --ulimit nofile=65536:65536 \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$REPO_TOP:/work" \
        -v "$MESON_CACHE_MOUNT:/cache" \
        -v "$PMOS_KEY_HOST:/tmp/pmos.rsa.pub:ro" \
        -e PMOS_REPO_URL="$PMOS_REPO_URL" \
        -e BUILD_HOME_BG="$BUILD_HOME_BG" \
        -e BUILD_APP_HANDLER="${BUILD_APP_HANDLER:-1}" \
        -e USE_VENDOR_PHOSH="$USE_VENDOR_PHOSH" \
        -e ATOMOS_CCACHE_MAXSIZE="${ATOMOS_CCACHE_MAXSIZE:-5G}" \
        "$ALPINE_IMAGE" /bin/sh \
        /work/iso-postmarketos/scripts/_lib-build-container-body.sh
}
