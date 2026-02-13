#!/bin/bash
set -ex

echo "=== Building custom distinst to increase recovery partition size ==="

# Function to locate library directory
get_libdir() {
    local arch=$(dpkg --print-architecture)
    local libdir="/usr/lib/$(grep -m1 ^$arch- /usr/share/dpkg/cputable | cut -f3)"
    if [ -z "$libdir" ]; then 
        libdir="/usr/lib/$(uname -m)-linux-gnu"
    fi
    echo "$libdir"
}

LIBDIR=$(get_libdir)
echo "Target library directory: $LIBDIR"

# Install build dependencies
# We need these to compile distinst. Some might already be in BUILD_PKGS.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git cargo clang libclang-dev make pkg-config libssl-dev gettext \
    libparted-dev libdbus-1-dev liblvm2-dev

# working directory
WORKDIR="/tmp/distinst-build"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Clone distinst
# We use a specific tag/commit if possible to match 24.04 version?
# But latest master is usually fine for Pop!_OS.
git clone https://github.com/pop-os/distinst.git .

# PATCH: Increase recovery partition size from 4GB (8388608 sectors) to 8GB (16777216 sectors)
# The constant is DEFAULT_RECOVER_SECTORS in src/lib.rs
if grep -q "DEFAULT_RECOVER_SECTORS: u64 = 8_388_608;" src/lib.rs; then
    echo "Patching DEFAULT_RECOVER_SECTORS..."
    sed -i 's/8_388_608/16_777_216/g' src/lib.rs
else
    echo "ERROR: Could not find DEFAULT_RECOVER_SECTORS constant in src/lib.rs. Source might have changed."
    grep "DEFAULT_RECOVER_SECTORS" src/lib.rs || true
    exit 1
    exit 1
fi

# PATCH: Change recovery partition filesystem from Fat32 to Ext4
# Fat32 has a 4GB file size limit. Our filesystem.squashfs is > 4GB.
echo "Patching recovery partition filesystem to Ext4..."
# Replace `PartitionBuilder::new(start, recovery_end, Fat32)` with `...Ext4)` (Line ~164)
sed -i 's/PartitionBuilder::new(start, recovery_end, Fat32)/PartitionBuilder::new(start, recovery_end, Ext4)/g' src/auto/options/apply.rs

# Replace `Fat32` with `Ext4` in the erase_config block for recovery partition.
# We focus on the block that calculates `end` using `recovery_sector` and then creates the partition.
# This avoids accidentally changing the EFI partition (which also uses Fat32).
sed -i '/recovery_sector);/,/mount("\/recovery"/ s/Fat32/Ext4/' src/auto/options/apply.rs

# Build release
echo "Building distinst packages (cli and ffi)..."
cargo build --release -p distinst_cli -p distinst_ffi

# Install binaries and libraries
echo "Installing distinst binary..."
if [ -f "target/release/distinst" ]; then
    cp target/release/distinst /usr/bin/distinst
else
    echo "WARNING: target/release/distinst not found. Checking cli..."
    # If cli/ produces it, it might be named differently or in a subdir?
    # standard cargo workspace build puts it in target/release/
    ls -l target/release/
fi

echo "Installing libdistinst.so..."
if [ -f "target/release/libdistinst.so" ]; then
    cp target/release/libdistinst.so "$LIBDIR/libdistinst.so"
    # Create valid symlinks for versioning (usually .0 or .0.5.0)
    # We force them to point to our new lib
    ln -sf libdistinst.so "$LIBDIR/libdistinst.so.0"
    ln -sf libdistinst.so "$LIBDIR/libdistinst.so.0.5.0" # approximate version
else
    echo "ERROR: target/release/libdistinst.so not found!"
    exit 1
fi

# Clean up
cd /
rm -rf "$WORKDIR"

# Remove build-only deps to save space?
# User wants BUILD_PKGS offline, so we keep cargo/clang.
# We can remove the dev libraries for parted/lvm if they are large?
# apt-get autoremove -y libparted-dev liblvm2-dev
# I'll leave them to be safe.
apt-get clean

echo "=== Custom distinst installed successfully ==="
