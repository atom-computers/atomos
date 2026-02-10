#!/bin/bash
# Install cocoindex in chroot environment
set -e

echo "Installing cocoindex..."

# Install Python dependencies
apt-get install -y python3-pip python3-venv python3-dev libpq-dev

# Install Rust (required for some Python packages)
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source /root/.cargo/env
fi

# Install cocoindex from local directory
cd /tmp/atomos-install/cocoindex

# Install Python dependencies and package from root
# requirements.txt does not exist, dependencies are in pyproject.toml
# pip3 install --break-system-packages -r python/requirements.txt || pip3 install -r python/requirements.txt

# Build and install Rust components
# Note: maturin (used by pip install) will also build the rust extension automatically.
# No manual cargo build/install needed for library crates.

# Install Python package from root
# cd ../.. # Removed as we are already in the root
pip3 install --break-system-packages --ignore-installed .

# Create cocoindex database in PostgreSQL
# This will be done on first boot by the user

echo "cocoindex installed successfully"
