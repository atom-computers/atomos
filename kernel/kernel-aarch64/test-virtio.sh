#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== virtio probe test ==="
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

echo "[3/3] Booting with virtio devices..."
QEMU_LOG=$(mktemp)
qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 128M \
    -nographic \
    -no-reboot \
    -device virtio-gpu-device \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -kernel "$BIN" \
    > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
sleep 8
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
OUTPUT=$(cat "$QEMU_LOG")
rm -f "$QEMU_LOG"

echo ""
echo "--- QEMU output ---"
echo "$OUTPUT"
echo "--- end ---"
echo ""

assert_contains() {
    if echo "$OUTPUT" | grep -qF "$1"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1"
        exit 1
    fi
}

assert_contains "kernel: quick test OK"
assert_contains "QEMU Virtio Keyboard"
assert_contains "QEMU Virtio Tablet"
assert_contains "input: keyboard driver initialized"
assert_contains "input: tablet driver initialized"
echo ""
echo "=== All virtio assertions passed ==="
