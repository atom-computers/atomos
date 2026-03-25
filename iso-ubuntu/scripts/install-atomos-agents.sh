#!/bin/bash
# Install AtomOS Python deep agents in chroot environment
set -euo pipefail

echo "Installing AtomOS agents service..."

# Copy agents package files to system
mkdir -p /opt/atomos/agents
cp -r /tmp/atomos-install/core/atomos-agents/* /opt/atomos/agents/

# Install the tmux attach script to a well-known path so the COSMIC
# applet can set SHELL= when launching cosmic-term.
mkdir -p /usr/local/share/atomos
cp /opt/atomos/agents/scripts/atomos-tmux-attach.sh /usr/local/share/atomos/
chmod +x /usr/local/share/atomos/atomos-tmux-attach.sh

# Install Python dependencies for agents service.
#
# browser-use must be installed FIRST with all its transitive deps
# (cdp-use, bubus, psutil, pydantic-settings, python-dotenv, httpx, …).
# It hard-pins anthropic==0.76.0, but that is intentionally overwritten
# by the second pip install which pulls in deepagents → langchain-anthropic
# → anthropic>=0.78.0.  The minor anthropic upgrade is backward-compatible
# and browser-use continues to work correctly.
#
# Some system-installed Python packages were placed by apt without a
# pip-compatible RECORD file.  Remove their dist-info so pip can freely
# upgrade them instead of failing with "RECORD file not found".
# This list covers every package that Ubuntu 24.04's debootstrap installs
# into /usr/lib/python3/dist-packages and that our dependency tree upgrades.
rm -rf /usr/lib/python3/dist-packages/urllib3-*.dist-info \
       /usr/lib/python3/dist-packages/PyJWT-*.dist-info \
       /usr/lib/python3/dist-packages/PyYAML-*.dist-info \
       /usr/lib/python3/dist-packages/six-*.dist-info \
       /usr/lib/python3/dist-packages/setuptools-*.dist-info \
       /usr/lib/python3/dist-packages/certifi-*.dist-info \
       /usr/lib/python3/dist-packages/requests-*.dist-info \
       /usr/lib/python3/dist-packages/idna-*.dist-info \
       /usr/lib/python3/dist-packages/charset_normalizer-*.dist-info \
       /usr/lib/python3/dist-packages/packaging-*.dist-info \
       /usr/lib/python3/dist-packages/pyparsing-*.dist-info \
       /usr/lib/python3/dist-packages/distro-*.dist-info 2>/dev/null || true


cd /opt/atomos/agents
pip3 install --break-system-packages browser-use
# ACP server runtime used by Zed (`from acp import ...` in acp_server.py).
# Keep this explicit so editor integration works even if project deps drift.
pip3 install --break-system-packages deepagents-acp
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
