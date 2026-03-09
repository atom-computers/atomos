#!/bin/bash
# Install cosmic-ext-applet-ollama in chroot environment
set -euo pipefail

echo "Installing cosmic-ext-applet-ollama..."

# Install Ollama first
curl -fsSL https://ollama.com/install.sh | sh

if ! command -v ollama &> /dev/null; then
    echo "FATAL: Ollama binary not found after install"
    exit 1
fi
systemctl enable ollama

# We need to pull the default model now so it gets baked into the ISO.
# Since systemd is not running inside this chroot, we run the server in the bg.
echo "Starting Ollama to pull smollm2:135m model..."
export OLLAMA_MODELS="/usr/share/ollama/.ollama/models"
ollama serve &
OLLAMA_PID=$!

# Wait for ollama daemon to be ready
echo "Waiting for Ollama service to start..."
timeout 30 bash -c 'until curl -s http://localhost:11434 > /dev/null; do sleep 1; done' || { echo "Failed to start Ollama daemon"; kill $OLLAMA_PID; exit 1; }

echo "Pulling smollm2:135m..."
ollama pull smollm2:135m

echo "Pulling nomic-embed-text (embedding model for tool registry)..."
ollama pull nomic-embed-text

echo "Stopping Ollama daemon..."
kill $OLLAMA_PID
wait $OLLAMA_PID || true

# Fix ownership so the ollama systemd service can access the downloaded models
echo "Fixing permissions for Ollama models..."
chown -R ollama:ollama /usr/share/ollama/.ollama

# Autoload model on boot so it's immediately ready for the API
cat > /usr/local/bin/ollama-preload.sh << 'OLLAMAEOF'
#!/bin/bash
curl -X POST http://localhost:11434/api/generate \
     -H "Content-Type: application/json" \
     -d '{"model": "smollm2:135m", "keep_alive": -1}' \
     --max-time 10 || true
OLLAMAEOF
chmod +x /usr/local/bin/ollama-preload.sh

cat > /etc/systemd/system/ollama-preload.service << 'EOF'
[Unit]
Description=Preload Ollama Model
After=ollama.service
Requires=ollama.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-preload.sh
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ollama-preload.service

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

# Set default panel configuration to enable applet 
mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/
cat > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings << 'EOF'
Some(([
    "com.system76.CosmicPanelWorkspacesButton",
    "com.system76.CosmicPanelAppButton",
    "com.system76.CosmicAppletTime",
], [
    "dev.heppen.ollama",
]))
EOF

# Match panel layout from the guest VM:
# keep standard status applets in the center segment and leave
# the Atomos Agent applet on the end segment.
cat > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center << 'EOF'
Some([
    "com.system76.CosmicAppletInputSources",
    "com.system76.CosmicAppletA11y",
    "com.system76.CosmicAppletStatusArea",
    "com.system76.CosmicAppletTiling",
    "com.system76.CosmicAppletAudio",
    "com.system76.CosmicAppletBluetooth",
    "com.system76.CosmicAppletNetwork",
    "com.system76.CosmicAppletBattery",
    "com.system76.CosmicAppletNotifications",
    "com.system76.CosmicAppletPower",
])
EOF

# Set custom Dock aesthetics and positioning
mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/
echo "0.4" > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/opacity

mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicPanel.Dock/v1/
echo "0.4" > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Dock/v1/opacity
echo "Left" > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Dock/v1/anchor
echo "M" > /etc/skel/.config/cosmic/com.system76.CosmicPanel.Dock/v1/size

mkdir -p /etc/skel/.config/cosmic/com.system76.CosmicTheme.Light/v1/
cat > /etc/skel/.config/cosmic/com.system76.CosmicTheme.Light/v1/corner_radii << 'EOF'
(
    radius_0: (0.0, 0.0, 0.0, 0.0),
    radius_xs: (4.0, 4.0, 4.0, 4.0),
    radius_s: (8.0, 8.0, 8.0, 8.0),
    radius_m: (16.0, 16.0, 16.0, 16.0),
    radius_l: (32.0, 32.0, 32.0, 32.0),
    radius_xl: (160.0, 160.0, 160.0, 160.0),
)
EOF

echo "cosmic-ext-applet-ollama installed successfully"
