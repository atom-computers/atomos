#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== virtio input e2e test ==="
echo ""

OBJCOPY="$(find "$(rustc --print sysroot)" -name 'llvm-objcopy' -type f 2>/dev/null | head -1)"
ELF="../target/aarch64-unknown-none-softfloat/release/kernel-aarch64"
BIN="$ELF.bin"

echo "[1/4] Building kernel..."
cargo build --release 2>&1 | tail -1
echo "  Build OK"

echo "[2/4] Converting to raw binary..."
"$OBJCOPY" -O binary "$ELF" "$BIN"
echo "  Objcopy OK"

echo "[3/4] Booting with input devices + QMP monitor..."
QEMU_LOG=$(mktemp)
MONITOR_SOCK=$(mktemp -u -t qemu-monitor-XXXXXX)
# Trap to clean up socket on exit
trap 'rm -f "$QEMU_LOG" "$MONITOR_SOCK" 2>/dev/null; [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true' EXIT

qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 128M \
    -nographic \
    -no-reboot \
    -device virtio-gpu-device \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -monitor "unix:$MONITOR_SOCK,server=on,wait=off" \
    -kernel "$BIN" \
    > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!

# Wait for QEMU to boot and socket to appear
sleep 3

echo "[4/4] Sending keyboard input via QEMU monitor..."
# Send a few key events via QMP (QEMU Monitor Protocol)
# sendkey with hold_time to ensure events are delivered
for key in a b c enter; do
    echo "sendkey $key" | socat - "UNIX-CONNECT:$MONITOR_SOCK" 2>/dev/null || true
    sleep 0.3
done

# Give the kernel time to process the events
sleep 3

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
OUTPUT=$(cat "$QEMU_LOG")

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

assert_contains "kernel-aarch64 booted"
assert_contains "input: keyboard driver initialized"
assert_contains "input: tablet driver initialized"
assert_contains "input: subscriber activated"

echo ""
echo "=== All e2e assertions passed ==="
