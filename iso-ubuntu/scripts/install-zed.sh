#!/bin/bash
# Install Zed editor in chroot environment.
#
# The tarball should already exist at /tmp/atomos-install/zed.tar.gz
# (downloaded by chroot.mk BEFORE entering the chroot, where network
# is guaranteed).  If missing, attempt a direct download as fallback.
set -euo pipefail

echo "Installing Zed Editor..."

TARBALL="/tmp/atomos-install/zed.tar.gz"

if [ ! -f "$TARBALL" ]; then
    echo "WARNING: Zed tarball not pre-staged — attempting download inside chroot..."
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) ZED_ARCH="aarch64" ;;
        x86_64)  ZED_ARCH="x86_64" ;;
        *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    curl -fsSL "https://cloud.zed.dev/releases/stable/latest/download?asset=zed&arch=${ZED_ARCH}&os=linux&source=docs" -o "$TARBALL"
fi

echo "Extracting Zed..."
mkdir -p /opt
tar -xzf "$TARBALL" -C /opt

# Find the actual extracted directory — the tarball naming varies across
# releases (zed.app, zed-linux-x86_64, zed-preview, etc.).
ZED_DIR=""
for candidate in /opt/zed.app /opt/zed-linux-* /opt/zed-preview* /opt/zed; do
    if [ -x "$candidate/bin/zed" ]; then
        ZED_DIR="$candidate"
        break
    fi
done

if [ -z "$ZED_DIR" ]; then
    ZED_BIN=$(find /opt -maxdepth 3 -name zed -type f -executable 2>/dev/null | head -1)
    if [ -n "$ZED_BIN" ]; then
        ZED_DIR=$(dirname "$(dirname "$ZED_BIN")")
    fi
fi

if [ -z "$ZED_DIR" ]; then
    echo "FATAL: Could not find Zed binary after extraction."
    echo "Contents of /opt:"
    find /opt -maxdepth 3 -ls 2>/dev/null || ls -laR /opt/
    exit 1
fi

echo "Zed found at: $ZED_DIR"

# Normalize to /opt/zed.app so all downstream paths are stable
if [ "$ZED_DIR" != "/opt/zed.app" ]; then
    echo "Renaming $ZED_DIR → /opt/zed.app"
    rm -rf /opt/zed.app
    mv "$ZED_DIR" /opt/zed.app
fi
ZED_DIR="/opt/zed.app"

# Verify the binary actually runs
if ! "$ZED_DIR/bin/zed" --version 2>/dev/null; then
    echo "WARNING: 'zed --version' failed (expected in chroot without display)"
fi

# Avoid Zed's first-run "Unsupported GPU" interstitial on COSMIC/Pop-style
# installs where PRIME discrete mode can cause llvmpipe fallback.
if [ -f /etc/prime-discrete ]; then
    PRIME_MODE=$(tr -d '[:space:]' < /etc/prime-discrete || true)
    if [ "$PRIME_MODE" != "off" ]; then
        echo "Setting /etc/prime-discrete to off for Zed GPU compatibility..."
        echo "off" > /etc/prime-discrete
    fi
fi

# Suppress the "Unsupported GPU" dialog unconditionally so users on VMs
# or software rendering (llvmpipe) never see a blocking first-run prompt.
echo "Setting ZED_ALLOW_EMULATED_GPU=1 system-wide..."
mkdir -p /etc/profile.d
cat > /etc/profile.d/zed-gpu.sh << 'GPUENV'
export ZED_ALLOW_EMULATED_GPU=1
GPUENV
mkdir -p /etc/environment.d
echo "ZED_ALLOW_EMULATED_GPU=1" > /etc/environment.d/50-zed-gpu.conf
if ! grep -q '^ZED_ALLOW_EMULATED_GPU=' /etc/environment 2>/dev/null; then
    echo "ZED_ALLOW_EMULATED_GPU=1" >> /etc/environment
fi

echo "Configuring Zed..."

# Wrapper script instead of a plain symlink — guarantees
# ZED_ALLOW_EMULATED_GPU=1 reaches every launch path (dock, terminal, agent).
cat > /usr/local/bin/zed << WRAPPER
#!/bin/sh
export ZED_ALLOW_EMULATED_GPU=1
exec "$ZED_DIR/bin/zed" "\$@"
WRAPPER
chmod +x /usr/local/bin/zed
ln -sf /usr/local/bin/zed /usr/bin/zed

# Verify the wrapper works
for link in /usr/local/bin/zed /usr/bin/zed; do
    if [ ! -x "$link" ]; then
        echo "FATAL: $link is not executable (target: $(readlink -f "$link" 2>/dev/null || echo missing))"
        exit 1
    fi
done
echo "Wrapper verified: /usr/local/bin/zed, /usr/bin/zed"

# Install desktop file
install -D "$ZED_DIR/share/applications/dev.zed.Zed.desktop" -t /usr/share/applications/
sed -i "s|Icon=zed|Icon=$ZED_DIR/share/icons/hicolor/512x512/apps/zed.png|g" /usr/share/applications/dev.zed.Zed.desktop
sed -i "s|Exec=zed|Exec=/usr/local/bin/zed|g" /usr/share/applications/dev.zed.Zed.desktop

echo "Adding Zed and Chromium to the Cosmic Dock..."
# COSMIC dock favorites are stored in com.system76.CosmicAppList/v1/favorites
# (RON list). Write both system defaults and per-user skeleton defaults.
for base in /usr/share/cosmic /etc/skel/.config/cosmic; do
mkdir -p "$base/com.system76.CosmicAppList/v1/"
cat > "$base/com.system76.CosmicAppList/v1/favorites" << 'EOF'
[
    "chromium-browser",
    "dev.zed.Zed",    
    "com.system76.CosmicFiles",
    "com.system76.CosmicTerm",
    "com.system76.CosmicSettings",
]
EOF
done

echo "Configuring AtomOS agent server for Zed (ACP)..."
mkdir -p /etc/skel/.config/zed
cat > /etc/skel/.config/zed/settings.json << 'SETTINGS'
{
  "theme": "One Dark",
  "agent_servers": {
    "AtomOS": {
      "type": "custom",
      "command": "/opt/atomos/agents/run_acp_server.sh"
    }
  }
}
SETTINGS

echo "Zed Editor installed successfully"
