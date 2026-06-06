#!/bin/bash
# Local preview of the light-earth background.
# Compiles the react application and starts a local web server to preview it in your browser.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIGHT_EARTH_DIR="$ROOT_DIR/iso-postmarketos/data/atomos-home-bg/light-earth"

echo "=== Building light-earth React application ==="
cd "$LIGHT_EARTH_DIR"
if [ ! -d "node_modules" ]; then
    echo "Installing node dependencies..."
    npm install
fi

echo "Compiling bundle using build.js..."
node build.js

echo "=== Starting preview web server ==="
echo "The preview will be available at http://localhost:8080/index.html"
echo "Press Ctrl+C to stop the server."

# Open browser if on macOS
if [ "$(uname -s)" = "Darwin" ]; then
    (sleep 1 && open "http://localhost:8080/index.html") &
fi

python3 -m http.server 8080
