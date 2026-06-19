#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== kernel-aarch64 TDD test ==="
echo ""

# Find llvm-objcopy from the Rust toolchain
OBJCOPY="$(find "$(rustc --print sysroot)" -name 'llvm-objcopy' -type f 2>/dev/null | head -1)"
if [ -z "$OBJCOPY" ]; then
    echo "FATAL: llvm-objcopy not found in Rust toolchain. Install llvm-tools-preview."
    exit 1
fi

# Build
echo "[1/3] Building kernel..."
cargo build --release 2>&1 | tail -1
echo "  Build OK"

# Workspace root is one level up (kernel-aarch64 is in a workspace at ../)
ELF="../target/aarch64-unknown-none-softfloat/release/kernel-aarch64"
BIN="$ELF.bin"

# Convert to raw binary
echo "[2/3] Converting to raw binary..."
"$OBJCOPY" -O binary "$ELF" "$BIN"
echo "  Objcopy OK"

# Run in QEMU, capture output
echo "[3/3] Booting in QEMU..."
# Run QEMU in background, kill after 3s (kernel spin-loops after printing)
QEMU_LOG=$(mktemp)
qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 128M \
    -nographic \
    -no-reboot \
    -kernel "$BIN" \
    > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
sleep 6
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
OUTPUT=$(cat "$QEMU_LOG")
rm -f "$QEMU_LOG"

echo ""
echo "--- QEMU output ---"
echo "$OUTPUT"
echo "--- end ---"
echo ""

# Assertions
assert_contains() {
    local expected="$1"
    if echo "$OUTPUT" | grep -qF "$expected"; then
        echo "  PASS: found \"$expected\""
    else
        echo "  FAIL: missing \"$expected\""
        exit 1
    fi
}

echo "Assertions:"
assert_contains "kernel-aarch64 booted"
assert_contains "kernel: quick test OK"

echo ""
echo "=== All assertions passed ==="
