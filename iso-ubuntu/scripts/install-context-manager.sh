#!/bin/bash
# Install AtomOS context-manager in chroot environment
set -euo pipefail

echo "Installing AtomOS context-manager..."

# Build context-manager
cd /tmp/atomos-install/core/context-manager

# Install Rust if not already installed (usually handled by ollama or globally, but ensure it's there)
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source /root/.cargo/env
fi

# Build release version
cargo build --release

# Install binary
cp target/release/context-manager /usr/local/bin/atomos-context-manager
chmod +x /usr/local/bin/atomos-context-manager

# Create systemd service file
cat > /etc/systemd/system/atomos-context-manager.service << 'EOF'
[Unit]
Description=AtomOS Context Manager Service
After=network.target postgresql.service surrealdb.service atomos-sync.service
Requires=postgresql.service surrealdb.service

[Service]
Type=simple
User=root
Environment="SURREAL_URL=ws://localhost:8000"
Environment="SURREAL_USER=root"
Environment="SURREAL_PASS=root"
Environment="SURREAL_NS=atomos"
Environment="SURREAL_DB=atomos"
ExecStart=/usr/local/bin/atomos-context-manager
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Enable context-manager service
systemctl enable atomos-context-manager

echo "AtomOS context-manager installed successfully"
