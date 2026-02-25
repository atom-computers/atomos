#!/bin/bash
# Install custom wallpapers in chroot environment
set -e

echo "Installing Custom Wallpapers..."

# Create backgrounds directory
mkdir -p /usr/share/backgrounds/atomos

# Copy custom wallpapers
if [ -d "/tmp/atomos-install/data/wallpapers" ]; then
    cp -r /tmp/atomos-install/data/wallpapers/* /usr/share/backgrounds/atomos/
fi

# Set default wallpaper for new users and live session
mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicBackground/v1/
cat > /etc/skel/.config/cosmic/com.system76.CosmicBackground/v1/all << 'EOF'
(
    output: "all",
    source: Path("/usr/share/backgrounds/atomos/frozen-exoplanet.jpg"),
    filter_by_theme: true,
    rotation_frequency: 300,
    filter_method: Lanczos,
    scaling_mode: Zoom,
    sampling_method: Alphanumeric,
)
EOF

# Give correct permissions
chmod -R 644 /usr/share/backgrounds/atomos/* || true

echo "Custom wallpapers installed successfully"
