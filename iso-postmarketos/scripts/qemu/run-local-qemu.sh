#!/bin/bash
set -euo pipefail

if [ "$#" -gt 2 ]; then
    echo "Usage: $0 [profile-env] [image-path]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV="${1:-config/arm64-virt.env}"
IMAGE_OVERRIDE="${2:-}"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

IMAGE_PATH="${IMAGE_OVERRIDE:-$ROOT_DIR/build/host-export-${PROFILE_NAME}/${PROFILE_NAME}.img}"
if [ ! -f "$IMAGE_PATH" ]; then
    echo "QEMU image not found: $IMAGE_PATH" >&2
    echo "Run: make build-qemu" >&2
    exit 1
fi

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "qemu-system-aarch64 is required." >&2
    exit 1
fi

resolve_accel() {
    if [ -n "${ATOMOS_QEMU_ACCEL:-}" ]; then
        printf '%s\n' "$ATOMOS_QEMU_ACCEL"
        return 0
    fi
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' "hvf"
            ;;
        Linux)
            if [ -e /dev/kvm ]; then
                printf '%s\n' "kvm"
            else
                printf '%s\n' "tcg"
            fi
            ;;
        *)
            printf '%s\n' "tcg"
            ;;
    esac
}

resolve_uefi_mode() {
    if [ -n "${ATOMOS_QEMU_EFI_CODE:-}" ]; then
        if [ -n "${ATOMOS_QEMU_EFI_VARS_TEMPLATE:-}" ]; then
            printf '%s\n' "pflash"
        else
            printf '%s\n' "bios"
        fi
        return 0
    fi
    if [ -n "${ATOMOS_QEMU_EFI_BIOS:-}" ]; then
        printf '%s\n' "bios"
        return 0
    fi
    if [ -f "/usr/share/AAVMF/AAVMF_CODE.fd" ] && [ -f "/usr/share/AAVMF/AAVMF_VARS.fd" ]; then
        printf '%s\n' "pflash"
        return 0
    fi
    if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" ]; then
        printf '%s\n' "bios"
        return 0
    fi
    if [ -f "/usr/local/share/qemu/edk2-aarch64-code.fd" ]; then
        printf '%s\n' "bios"
        return 0
    fi
    if [ -f "/usr/share/edk2/aarch64/QEMU_EFI.fd" ]; then
        printf '%s\n' "bios"
        return 0
    fi
    if [ -f "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" ]; then
        printf '%s\n' "bios"
        return 0
    fi
    printf '%s\n' "none"
}

ACCEL="$(resolve_accel)"
MEMORY_MB="${ATOMOS_QEMU_MEMORY_MB:-${PMOS_QEMU_MEMORY_MB:-4096}}"
CPUS="${ATOMOS_QEMU_CPUS:-4}"
SSH_FWD_PORT="${ATOMOS_QEMU_SSH_FWD_PORT:-2222}"
EFI_MODE="$(resolve_uefi_mode)"

CPU_MODEL="cortex-a72"
if [ "$ACCEL" = "kvm" ] || [ "$ACCEL" = "hvf" ]; then
    CPU_MODEL="host"
fi

DISPLAY_ARGS=()
if [ "${ATOMOS_QEMU_HEADLESS:-0}" = "1" ]; then
    DISPLAY_ARGS=(-nographic)
else
    DISPLAY_ARGS=(-display default)
fi

DRIVE_ARGS=(
    -drive "if=none,file=$IMAGE_PATH,format=raw,id=disk0"
    -device "virtio-blk-pci,drive=disk0"
)

UEFI_ARGS=()
if [ "$EFI_MODE" = "pflash" ]; then
    EFI_CODE="${ATOMOS_QEMU_EFI_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}"
    EFI_VARS_TEMPLATE="${ATOMOS_QEMU_EFI_VARS_TEMPLATE:-/usr/share/AAVMF/AAVMF_VARS.fd}"
    EFI_VARS_DIR="$ROOT_DIR/build/qemu"
    EFI_VARS="$EFI_VARS_DIR/${PROFILE_NAME}-AAVMF_VARS.fd"
    mkdir -p "$EFI_VARS_DIR"
    if [ ! -f "$EFI_VARS" ]; then
        cp "$EFI_VARS_TEMPLATE" "$EFI_VARS"
    fi
    UEFI_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=$EFI_CODE"
        -drive "if=pflash,format=raw,file=$EFI_VARS"
    )
elif [ "$EFI_MODE" = "bios" ]; then
    EFI_BIOS="${ATOMOS_QEMU_EFI_BIOS:-}"
    if [ -z "$EFI_BIOS" ]; then
        for candidate in \
            "${ATOMOS_QEMU_EFI_CODE:-}" \
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" \
            "/usr/local/share/qemu/edk2-aarch64-code.fd" \
            "/usr/share/edk2/aarch64/QEMU_EFI.fd" \
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"; do
            if [ -n "$candidate" ] && [ -f "$candidate" ]; then
                EFI_BIOS="$candidate"
                break
            fi
        done
    fi
    if [ -n "$EFI_BIOS" ]; then
        UEFI_ARGS=(-bios "$EFI_BIOS")
    fi
fi

if [ "${#UEFI_ARGS[@]}" -eq 0 ]; then
    echo "WARN: no AArch64 UEFI firmware found; install qemu-efi-aarch64/AAVMF or set ATOMOS_QEMU_EFI_BIOS." >&2
fi

echo "Launching QEMU:"
echo "  image: $IMAGE_PATH"
echo "  accel: $ACCEL  cpu: $CPU_MODEL  mem: ${MEMORY_MB}M  smp: $CPUS"
echo "  ssh:   host 127.0.0.1:${SSH_FWD_PORT} -> guest :22 (SLIRP user netdev)"
echo "         (172.16.42.1 is USB gadget on hardware; bridge/tap is not configured here.)"

exec qemu-system-aarch64 \
    -machine "virt,accel=${ACCEL}" \
    -cpu "$CPU_MODEL" \
    -smp "$CPUS" \
    -m "$MEMORY_MB" \
    "${UEFI_ARGS[@]}" \
    "${DRIVE_ARGS[@]}" \
    -device virtio-gpu-pci \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_FWD_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    "${DISPLAY_ARGS[@]}"
