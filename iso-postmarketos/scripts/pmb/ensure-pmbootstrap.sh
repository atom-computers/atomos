#!/bin/bash
# Ensure pmbootstrap is available natively. On a real Linux host (e.g.
# Multipass VM) this is required because the 'install' step creates loop
# device partitions (/dev/loopXp1) that do not work inside Docker containers.
set -euo pipefail

if command -v pmbootstrap >/dev/null 2>&1; then
    exit 0
fi

echo "pmbootstrap not found — installing via pip..."

if ! command -v pip3 >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq python3-pip python3-venv >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add --no-interactive --quiet py3-pip
    else
        echo "ERROR: Cannot install pip3. Install pmbootstrap manually:" >&2
        echo "  pip3 install --user pmbootstrap" >&2
        exit 1
    fi
fi

if command -v pipx >/dev/null 2>&1; then
    pipx install pmbootstrap
elif pip3 install --user --break-system-packages pmbootstrap 2>/dev/null; then
    true
elif pip3 install --user pmbootstrap 2>/dev/null; then
    true
else
    echo "ERROR: pip3 install failed. Trying with venv..." >&2
    python3 -m venv /tmp/.pmb-venv
    /tmp/.pmb-venv/bin/pip install pmbootstrap
    sudo ln -sf /tmp/.pmb-venv/bin/pmbootstrap /usr/local/bin/pmbootstrap
fi

# Verify
PMB_PATH="$(command -v pmbootstrap 2>/dev/null || true)"
if [ -z "$PMB_PATH" ]; then
    USER_BIN="$HOME/.local/bin"
    if [ -x "$USER_BIN/pmbootstrap" ]; then
        export PATH="$USER_BIN:$PATH"
        PMB_PATH="$USER_BIN/pmbootstrap"
    fi
fi

if [ -z "$PMB_PATH" ]; then
    echo "ERROR: pmbootstrap installed but not in PATH." >&2
    echo "  Add ~/.local/bin to your PATH and retry." >&2
    exit 1
fi

echo "pmbootstrap installed: $PMB_PATH ($(pmbootstrap --version 2>&1 || true))"
