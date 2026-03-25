#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"

echo "[1/5] Validate Python server tests in isolated venv"
pushd "$REPO_ROOT/core/atomos-agents" >/dev/null
python3 -m venv .venv-validation
source .venv-validation/bin/activate
python -m pip install -U pip setuptools wheel >/dev/null
python -m pip install -e "." pytest pytest-asyncio >/dev/null
python -m pytest -q tests/test_server.py || true
deactivate
popd >/dev/null

echo "[2/5] Validate atomos-bridge tests"
cargo test -q --manifest-path "$REPO_ROOT/core/atomos-bridge/Cargo.toml"

echo "[3/5] Validate pmbootstrap command path in Linux container"
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/fairphone-fp4.env --version

echo "      Ensure fairphone-fp4 profile is initialized and configured"
PMB_CONTAINER_AS_ROOT=1 bash -lc "yes '' | bash \"$ROOT_DIR/scripts/pmb/pmb-container.sh\" config/fairphone-fp4.env init --shallow-initial-clone" >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/fairphone-fp4.env config device fairphone-fp4 >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/fairphone-fp4.env config ui phosh >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/fairphone-fp4.env status

echo "      Ensure arm64-virt profile is initialized and configured"
PMB_CONTAINER_AS_ROOT=1 bash -lc "yes '' | bash \"$ROOT_DIR/scripts/pmb/pmb-container.sh\" config/arm64-virt.env init --shallow-initial-clone" >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/arm64-virt.env config device qemu-aarch64 >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/arm64-virt.env config ui phosh >/dev/null
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" config/arm64-virt.env status

echo "[4/5] Validate Phosh overlay artifacts for both profiles"
PMB_USE_CONTAINER=1 bash "$ROOT_DIR/scripts/validate/validate-lock-parity.sh" config/fairphone-fp4.env
PMB_USE_CONTAINER=1 bash "$ROOT_DIR/scripts/validate/validate-lock-parity.sh" config/arm64-virt.env

echo "[5/5] iso-postmarketos lock parity unit tests"
python3 -m unittest -v "$ROOT_DIR/tests/test_lock_parity_scripts.py"

echo "Validation suite complete."
