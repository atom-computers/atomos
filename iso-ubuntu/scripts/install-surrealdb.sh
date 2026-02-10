#!/bin/bash
# Install SurrealDB in chroot environment
set -e

echo "Installing SurrealDB..."

# Install dependencies
apt-get install -y curl

# Download and install SurrealDB binary
curl -sSf https://install.surrealdb.com | sh

# Move binary to system path
# Binary is already installed to /usr/local/bin by the installer script
chmod +x /usr/local/bin/surreal

# Create SurrealDB data directory
mkdir -p /var/lib/surrealdb

# Create systemd service file
cat > /etc/systemd/system/surrealdb.service << 'EOF'
[Unit]
Description=SurrealDB Database
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/surreal start --log trace --user root --pass root file:/var/lib/surrealdb/data.db
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable SurrealDB service
systemctl enable surrealdb

echo "SurrealDB installed successfully"
