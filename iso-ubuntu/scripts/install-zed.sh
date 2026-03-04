#!/bin/bash
# Install Zed editor in chroot environment
set -e

echo "Installing Zed Editor..."

# Determine architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    ZED_ARCH="aarch64"
elif [ "$ARCH" = "x86_64" ]; then
    ZED_ARCH="x86_64"
else
    echo "Unsupported architecture for Zed: $ARCH"
    exit 0
fi

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "Downloading Zed for $ZED_ARCH..."
curl -fsSL "https://cloud.zed.dev/releases/stable/latest/download?asset=zed&arch=${ZED_ARCH}&os=linux&source=docs" -o zed.tar.gz

echo "Extracting Zed..."
mkdir -p /opt
tar -xzf zed.tar.gz -C /opt

echo "Configuring Zed..."
# Link binary
ln -sf /opt/zed.app/bin/zed /usr/local/bin/zed

# Install desktop file
install -D /opt/zed.app/share/applications/dev.zed.Zed.desktop -t /usr/share/applications/
sed -i "s|Icon=zed|Icon=/opt/zed.app/share/icons/hicolor/512x512/apps/zed.png|g" /usr/share/applications/dev.zed.Zed.desktop
sed -i "s|Exec=zed|Exec=/opt/zed.app/bin/zed|g" /usr/share/applications/dev.zed.Zed.desktop

echo "Adding Zed to the Cosmic Dock..."
# Append Zed to the dock pinned applications list
mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicAppLibrary/v1/

cat > /etc/skel/.config/cosmic/com.system76.CosmicAppLibrary/v1/pinned << 'EOF'
[
    "dev.zed.Zed",
    "firefox",
    "cosmic-files",
    "cosmic-term",
    "cosmic-settings",
]
EOF

echo "Zed Editor installed successfully"
rm -rf "$WORKDIR"
