# shellcheck shell=bash
# scripts/_lib-greetd-guarantee.sh -- last-line-of-defence sweep that
# verifies+repairs everything greetd needs at boot.
#
# This is intentionally cheap (a few file appends + one chroot getent
# check) and IDEMPOTENT, so the orchestrator can call it as many
# times as it likes. v2 calls it twice (after overlays, before pack);
# v1 (build-fairphone4.sh) calls it once at the end of step 4 as a
# hot-fix for the still-shipping pipeline.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME ROOT_DIR

atomos_greetd_guarantee() {
    local label="${1:-default}"
    echo "=== greetd guarantee sweep [$label] ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$ROOT_DIR/scripts/_lib-greetd-guarantee-body.sh:/lib-greetd-guarantee-body.sh:ro" \
        -e ATOMOS_FP4V2_DEBUG_NO_GREETD="${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" \
        "$ALPINE_IMAGE" /bin/sh /lib-greetd-guarantee-body.sh
}
