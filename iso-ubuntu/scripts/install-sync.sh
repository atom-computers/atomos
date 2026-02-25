#!/bin/bash
# Install AtomOS sync service in chroot environment
set -e

echo "Installing AtomOS sync service..."

# Copy sync service files to system
mkdir -p /opt/atomos/sync
cp -r /tmp/atomos-install/core/sync-manager/* /opt/atomos/sync/

# Install Python dependencies for sync service
cd /opt/atomos/sync
pip3 install --break-system-packages -r requirements.txt || pip3 install -r requirements.txt

# Install syncevolution for GNOME Contacts integration
apt-get update
apt-get install -y syncevolution

# Create systemd service file
cat > /etc/systemd/system/atomos-sync.service << 'EOF'
[Unit]
Description=AtomOS Filesystem Sync Service
After=network.target postgresql.service surrealdb.service
Requires=postgresql.service surrealdb.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/atomos/sync
Environment="COCOINDEX_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/cocoindex"
Environment="HOME_DIR=/home"
Environment="CONVERSATION_DIR=/var/lib/atomos/conversations"
Environment="CONTACTS_DIR=/var/lib/atomos/contacts"
Environment="MCP_SERVERS_CONFIG_PATH=/etc/atomos/mcp_servers.json"
ExecStart=/usr/bin/python3 /opt/atomos/sync/main.py
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Enable sync service
systemctl enable atomos-sync

echo "AtomOS sync service installed successfully"
