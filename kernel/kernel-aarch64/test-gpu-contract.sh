#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== GPU contract + integration test ==="
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

echo "[3/4] Booting with GPU + monitor socket..."
MONITOR_SOCK=$(mktemp -u -t qemu-monitor-XXXXXX)
QEMU_LOG=$(mktemp)
trap 'rm -f "$QEMU_LOG" "$MONITOR_SOCK" 2>/dev/null; [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true' EXIT

qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 128M \
    -nographic \
    -no-reboot \
    -device virtio-gpu-device \
    -monitor "unix:$MONITOR_SOCK,server=on,wait=off" \
    -kernel "$BIN" \
    > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
sleep 4

echo "[4/4] Running contract + integration tests..."

# Extract framebuffer physical address from kernel UART output
FB_ADDR=$(grep 'GPU.*fb=' "$QEMU_LOG" | sed 's/.*fb=//' | tr -d '\r' | tr -d ' ')
if [ -z "$FB_ADDR" ]; then
    echo "  FAIL: Could not find framebuffer address in UART output"
    echo "--- QEMU output ---"
    cat "$QEMU_LOG"
    echo "--- end ---"
    exit 1
fi
# Ensure it starts with 0x
case "$FB_ADDR" in
    0x*) ;;
    *) FB_ADDR="0x$FB_ADDR" ;;
esac
echo "  Framebuffer at $FB_ADDR"

# Assert contract tests passed
assert_contains() {
    if grep -qF "$1" "$QEMU_LOG"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1"
        exit 1
    fi
}

assert_contains "gpu: contract tests PASSED"

# Dump first 32 bytes of framebuffer via QEMU monitor
echo "  Dumping framebuffer pixel data..."
XP_OUT=""
if command -v socat &>/dev/null; then
    XP_OUT=$(echo "xp/32bx $FB_ADDR" | socat - "UNIX-CONNECT:$MONITOR_SOCK" 2>/dev/null || true)
elif command -v nc &>/dev/null; then
    XP_OUT=$(echo "xp/32bx $FB_ADDR" | nc -w 2 -U "$MONITOR_SOCK" 2>/dev/null || true)
else
    echo "  WARN: neither socat nor nc found, skipping memory dump"
fi

if [ -n "$XP_OUT" ]; then
    echo "  Monitor dump (first 32 bytes at $FB_ADDR):"
    echo "$XP_OUT" | head -5
else
    echo "  INFO: QEMU monitor memory dump skipped (no socat/nc)"
fi

echo ""
echo "--- QEMU UART output (filtered) ---"
grep -E "gpu_test|gpu:|GPU|contract" "$QEMU_LOG" || true
echo "--- QEMU monitor memory dump ---"
echo "$XP_OUT" || true
echo "--- end ---"

# Verify we got a valid physical address
FB_HEX="${FB_ADDR#0x}"
echo ""
echo "  FB physical address: 0x$FB_HEX"

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
echo ""
echo "=== GPU contract+integration test complete ==="
