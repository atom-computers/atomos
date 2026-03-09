#!/bin/bash
# Install user-facing Chromium browser by wrapping the Playwright Chromium
# binary that install-atomos-agents.sh already placed at /opt/atomos/browsers.
# Sets Chromium as the default web browser and ensures its icon shows
# correctly in the COSMIC dock.
set -euo pipefail

echo "Configuring Chromium as default browser..."

BROWSERS_PATH="/opt/atomos/browsers"

# Locate the Playwright-installed Chromium binary.
CHROME_BIN=$(find "$BROWSERS_PATH" -name "chrome" -path "*/chrome-linux*/chrome" -type f -executable 2>/dev/null | head -1)

if [ -z "$CHROME_BIN" ]; then
    echo "FATAL: Playwright Chromium not found under $BROWSERS_PATH"
    echo "Ensure install-atomos-agents.sh runs before this script."
    exit 1
fi

CHROME_DIR=$(dirname "$CHROME_BIN")
echo "Using Chromium at: $CHROME_DIR"

# ── Wrapper script ────────────────────────────────────────────────────────
# --class forces the Wayland app-id to match the .desktop filename so the
# COSMIC dock can look up the correct icon for a running Chromium window.
cat > /usr/local/bin/chromium-browser << WRAPPER
#!/bin/bash
exec "$CHROME_BIN" \
  --class=chromium-browser \
  --no-sandbox \
  --no-default-browser-check \
  --no-first-run \
  "\$@"
WRAPPER
chmod +x /usr/local/bin/chromium-browser
ln -sf /usr/local/bin/chromium-browser /usr/bin/chromium-browser

# ── Icon ──────────────────────────────────────────────────────────────────
# Playwright's Chromium ships product_logo PNGs.  Copy the largest available
# into the hicolor icon theme so the desktop file's Icon= resolves.
ICON_INSTALLED=false
ICON_PATH="/usr/share/pixmaps/chromium-browser.png"
for size in 128 64 48 32 24 16; do
    ICON_SRC=$(find "$CHROME_DIR" -name "product_logo_${size}.png" 2>/dev/null | head -1)
    if [ -n "$ICON_SRC" ]; then
        mkdir -p "/usr/share/icons/hicolor/${size}x${size}/apps"
        cp "$ICON_SRC" "/usr/share/icons/hicolor/${size}x${size}/apps/chromium-browser.png"
        if [ "$size" = "128" ]; then
            mkdir -p /usr/share/pixmaps
            cp "$ICON_SRC" "$ICON_PATH"
        fi
        ICON_INSTALLED=true
    fi
done

if ! $ICON_INSTALLED; then
    echo "WARNING: No product_logo PNGs found in Playwright Chromium."
    echo "The dock may fall back to a generic icon."
fi

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Desktop entry ─────────────────────────────────────────────────────────
cat > /usr/share/applications/chromium-browser.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Chromium
GenericName=Web Browser
Comment=Access the Internet
Icon=/usr/share/pixmaps/chromium-browser.png
Exec=chromium-browser %U
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=chromium-browser
DESKTOP

# Some COSMIC defaults still pin "firefox". Override that launcher so clicking
# the existing dock favorite reliably opens Chromium with the Chromium icon/name.
cat > /usr/share/applications/firefox.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Chromium
GenericName=Web Browser
Comment=Access the Internet
Icon=/usr/share/pixmaps/chromium-browser.png
Exec=chromium-browser %U
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=chromium-browser
DESKTOP

# ── Default browser (xdg MIME associations) ───────────────────────────────
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/mimeapps.list << 'MIME'
[Default Applications]
text/html=chromium-browser.desktop
x-scheme-handler/http=chromium-browser.desktop
x-scheme-handler/https=chromium-browser.desktop
x-scheme-handler/about=chromium-browser.desktop
x-scheme-handler/unknown=chromium-browser.desktop
MIME

echo "Chromium browser configured successfully"
