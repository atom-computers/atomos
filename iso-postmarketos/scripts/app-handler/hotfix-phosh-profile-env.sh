#!/bin/bash
# Install /etc/atomos/phosh-profile.env on a running device (SSH).
# Use when diagnose shows phosh-profile.env missing but handler is installed.
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 bash scripts/app-handler/hotfix-phosh-profile-env.sh \
#     config/arm64-virt.env user@localhost
#
# Alpine OpenDoas has no -S; elevation uses doas -n (wheel nopass overlay), sudo -S,
# or expect + ssh -tt. Override: ATOMOS_APP_HANDLER_REMOTE_SUDO_PASSWORD=...
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
[ -f "$ROOT_DIR/$PROFILE_ENV" ] && . "$ROOT_DIR/$PROFILE_ENV"

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
REMOTE_SUDO_PASSWORD="${ATOMOS_APP_HANDLER_REMOTE_SUDO_PASSWORD:-$SSH_PASSWORD}"

SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

REMOTE_SCRIPT=$(cat <<'EOF'
set -eu
install -d /etc/atomos
cat > /etc/atomos/phosh-profile.env <<'ENVEOF'
ATOMOS_UI_PROFILE=phosh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1
ATOMOS_APP_HANDLER_TAKES_OVER=1
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1
ENVEOF
chmod 0644 /etc/atomos/phosh-profile.env
echo installed:
cat /etc/atomos/phosh-profile.env
EOF
)

# shellcheck source=scripts/app-handler/_lib-remote-elevate.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib-remote-elevate.sh"

echo "Installing phosh-profile.env on $SSH_TARGET ..."
atomos_remote_run_elevated "$SSH_TARGET" "$REMOTE_SCRIPT"

echo "Done. Log out of phrog / restart greetd, then log in again so phosh-session picks up the env."
