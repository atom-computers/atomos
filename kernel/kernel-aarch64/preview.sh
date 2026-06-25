#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== GPU preview — white bg + black rectangle ==="
echo ""

OBJCOPY="$(find "$(rustc --print sysroot)" -name 'llvm-objcopy' -type f 2>/dev/null | head -1)"
ELF="../target/aarch64-unknown-none-softfloat/release/kernel-aarch64"
BIN="$ELF.bin"

echo "[1/3] Building kernel..."
cargo build --release 2>&1 | tail -1
echo "  Build OK"

echo "[2/3] Converting to raw binary..."
"$OBJCOPY" -O binary "$ELF" "$BIN"
echo "  Objcopy OK"

echo "[3/3] Booting with GPU display..."
echo "  (Look for the QEMU window — white bg, centered black rectangle)"
echo "  Press Ctrl+C or close window to stop."
echo ""

# qemu-system-aarch64 \
#     -M virt,gic-version=3 \
#     -cpu cortex-a72 \
#     -m 128M \
#     -no-reboot \
#     -device virtio-gpu-pci,xres=720,yres=1440 \
#     -display cocoa,show-cursor=on \
#     -device virtio-keyboard-device \
#     -device virtio-tablet-device \
#     -serial stdio \
#     -kernel "$BIN" \
#     2>&1

qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 128M \
    -no-reboot \
    -device virtio-gpu-pci,xres=720,yres=1440 \
    -display cocoa,show-cursor=on \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -serial stdio \
    -kernel "$BIN" \
    2>&1
