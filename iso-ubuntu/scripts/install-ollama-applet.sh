#!/bin/bash
# Install cosmic-ext-applet-ollama in chroot environment
set -e

echo "Installing cosmic-ext-applet-ollama..."

# Install Ollama first
curl -fsSL https://ollama.com/install.sh | sh

# Install build dependencies
apt-get install -y just pkg-config libxkbcommon-dev libwayland-dev

# Set PKG_CONFIG_PATH to include standard library locations
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig

# Install Rust if not already installed
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source /root/.cargo/env
fi

# Build cosmic-ext-applet-ollama
cd /tmp/atomos-install/cosmic-ext-applet-ollama

# Build release version
just build-release

# Install the applet
just install

# Alternative manual installation if just install doesn't work:
# Copy binary to system path
# cp target/release/cosmic-ext-applet-ollama /usr/bin/cosmic-ext-applet-ollama
# chmod +x /usr/bin/cosmic-ext-applet-ollama

# Create applet directory structure
# mkdir -p /usr/share/cosmic/com.system76.CosmicAppletOllama
# cp -r res/* /usr/share/cosmic/com.system76.CosmicAppletOllama/ || true

echo "cosmic-ext-applet-ollama installed successfully"
echo "Note: Users will need to add the applet to their panel after login"
