#!/bin/bash
set -e

echo "Configuring Live Environment..."

# Create the check script
cat > /usr/local/bin/atomos-live-check << 'EOF'
#!/bin/bash
if grep -q "atomos-install" /proc/cmdline; then
    echo "Installer mode detected. Launching installer..."
    # Wait a bit for the desktop to fully load
    sleep 5
    io.elementary.installer.wrapper
else
    echo "Live mode detected."
fi
EOF

chmod +x /usr/local/bin/atomos-live-check

# Create autostart entry
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/atomos-live-check.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=AtomOS Live Check
Exec=/usr/local/bin/atomos-live-check
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

echo "Live environment configured."
