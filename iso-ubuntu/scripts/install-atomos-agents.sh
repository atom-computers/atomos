#!/bin/bash
# Install AtomOS Python deep agents in chroot environment
set -e

echo "Installing AtomOS agents service..."

# Copy agents package files to system
mkdir -p /opt/atomos/agents
cp -r /tmp/atomos-install/core/atomos-agents/* /opt/atomos/agents/

# Install Python dependencies for agents service
cd /opt/atomos/agents
pip3 install --break-system-packages .

# Create systemd service file
# Assuming `atomos-agents` will install an executable script or we can run the correct python script
cat > /etc/systemd/system/atomos-agents.service << 'EOF'
[Unit]
Description=AtomOS Agents Service
After=network.target atomos-context-manager.service atomos-task-manager.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/atomos/agents/src
Environment="PYTHONPATH=/opt/atomos/agents/src"
ExecStart=/usr/bin/python3 /opt/atomos/agents/src/server.py
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Enable agents service
systemctl enable atomos-agents

echo "AtomOS agents service installed successfully"
