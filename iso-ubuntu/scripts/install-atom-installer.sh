#!/bin/bash
set -e

echo "Installing Atom Installer (fork of Pop!_Installer)..."

# Source directory for atom-installer
SRC_DIR="/tmp/atomos-install/atom-installer"

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: atom-installer source not found at $SRC_DIR"
    exit 1
fi

cd "$SRC_DIR"

# Install build dependencies if missing (though they should be in 24.04.mk)
# We can't easily install them here if not root/chrooted properly or if apt is locked, 
# so we rely on 24.04.mk BUILD_PKGS.

# Build with Meson
echo "Configuring with Meson..."
rm -rf build
meson setup build --prefix=/usr --sysconfdir=/etc

echo "Building with Ninja..."
ninja -C build

echo "Installing..."
ninja -C build install

# Create/Update desktop entry
if [ -f "/usr/share/applications/io.elementary.installer.desktop" ]; then
    cp "/usr/share/applications/io.elementary.installer.desktop" /usr/share/applications/atom-installer.desktop
    sed -i 's/Name=Pop!_OS Installer/Name=Install AtomOS/g' /usr/share/applications/atom-installer.desktop
    sed -i 's/Exec=io.elementary.installer/Exec=io.elementary.installer/g' /usr/share/applications/atom-installer.desktop
    # We might want to rename the binary or keep it as io.elementary.installer
    # The meson build installs 'io.elementary.installer'.
fi

echo "Atom Installer installed successfully."
