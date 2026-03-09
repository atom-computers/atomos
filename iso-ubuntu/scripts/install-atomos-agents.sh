#!/bin/bash
# Install AtomOS Python deep agents in chroot environment
set -euo pipefail

echo "Installing AtomOS agents service..."

# Copy agents package files to system
mkdir -p /opt/atomos/agents
cp -r /tmp/atomos-install/core/atomos-agents/* /opt/atomos/agents/

# Install Python dependencies for agents service.
#
# browser-use must be installed FIRST with all its transitive deps
# (cdp-use, bubus, psutil, pydantic-settings, python-dotenv, httpx, …).
# It hard-pins anthropic==0.76.0, but that is intentionally overwritten
# by the second pip install which pulls in deepagents → langchain-anthropic
# → anthropic>=0.78.0.  The minor anthropic upgrade is backward-compatible
# and browser-use continues to work correctly.
cd /opt/atomos/agents
pip3 install --break-system-packages browser-use
pip3 install --break-system-packages .

# Ensure Chromium binary is available for browser automation.
# browser-use v0.12+ uses cdp-use (Chrome DevTools Protocol) but still
# needs a Chromium binary on the system.  playwright install provides one
# in a well-known location; install-deps pulls in OS-level libraries.
#
# PLAYWRIGHT_BROWSERS_PATH is set to a shared location so that the binary
# is accessible regardless of which user runs the service (root via systemd,
# george interactively, etc.).
export PLAYWRIGHT_BROWSERS_PATH=/opt/atomos/browsers
playwright install chromium
playwright install-deps chromium

# Create systemd service file
# Assuming `atomos-agents` will install an executable script or we can run the correct python script
cat > /etc/systemd/system/atomos-agents.service << 'EOF'
[Unit]
Description=AtomOS Agents Service
# graphical.target ensures the Wayland compositor (cosmic-comp) is up before
# this service starts, so Chromium can connect to the display.
After=network.target graphical.target surrealdb.service ollama.service atomos-context-manager.service atomos-task-manager.service
Wants=surrealdb.service ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/atomos/agents/src
Environment="PYTHONPATH=/opt/atomos/agents/src"
Environment="PLAYWRIGHT_BROWSERS_PATH=/opt/atomos/browsers"
# Forward the Wayland display socket from the active graphical session so that
# Chromium (headless=False) can render on the COSMIC desktop.
PassEnvironment=WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY
ExecStart=/usr/bin/python3 /opt/atomos/agents/src/server.py
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=graphical.target
EOF

# Enable agents service
systemctl enable atomos-agents

echo "AtomOS agents service installed successfully"
