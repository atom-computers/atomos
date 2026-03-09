#!/bin/bash
# Install cocoindex in chroot environment
set -euo pipefail

echo "Installing cocoindex..."

# Install system dependencies (libpq needed at runtime for PostgreSQL)
apt-get install -y python3-pip python3-dev libpq-dev

# Install pre-built wheel from PyPI (includes Rust extension)
pip3 install --break-system-packages --ignore-installed cocoindex

if ! python3 -c "import cocoindex" 2>/dev/null; then
    echo "FATAL: cocoindex not importable after install"
    exit 1
fi

echo "cocoindex installed successfully"
