#!/bin/bash
# Flash the built rootfs + kernel using the same pmbootstrap workdir as
# 'make build'. This avoids the PMB_WORK_OVERRIDE mismatch that happens
# when calling pmb.sh directly without the right environment.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <profile-env> [rootfs|kernel|both]" >&2
    exit 1
fi

PROFILE_ENV="$1"
WHAT="${2:-both}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

# Resolve the same PMB_WORK_OVERRIDE that 'make build' uses.
if [ -n "${SUDO_USER:-}" ]; then
    BASE_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    BASE_HOME="$HOME"
fi
export PMB_WORK_OVERRIDE="${PMB_WORK_OVERRIDE:-$BASE_HOME/.atomos-pmbootstrap-work/$PROFILE_NAME}"

echo "Using pmbootstrap work dir: $PMB_WORK_OVERRIDE"
if [ ! -d "$PMB_WORK_OVERRIDE" ]; then
    echo "ERROR: work dir not found: $PMB_WORK_OVERRIDE" >&2
    echo "  Run 'make build' first." >&2
    exit 1
fi

if [ "$WHAT" = "rootfs" ] || [ "$WHAT" = "both" ]; then
    echo "Flashing rootfs..."
    bash "$PMB_HOST" "$PROFILE_ENV_SOURCE" flasher flash_rootfs
fi

if [ "$WHAT" = "kernel" ] || [ "$WHAT" = "both" ]; then
    echo "Flashing kernel..."
    bash "$PMB_HOST" "$PROFILE_ENV_SOURCE" flasher flash_kernel
fi

echo "Flash complete. Reboot the device."
