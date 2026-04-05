#!/usr/bin/env bash
# SSH to an AtomOS/postmarketOS device. Optional sshpass when a password is set via env
# (do not commit real passwords).
#
# Usage (from iso-postmarketos/):
#   export ATOMOS_DEVICE_SSHPASS='…'
#   bash scripts/device/atomos-device-ssh.sh
#   bash scripts/device/atomos-device-ssh.sh 'uname -a'
#
# Env:
#   ATOMOS_DEVICE_HOST   default 172.16.42.1
#   ATOMOS_DEVICE_USER   default user
#   ATOMOS_DEVICE_SSH_PORT default 22
#   ATOMOS_DEVICE_SSHPASS or SSHPASS  passed to sshpass -e
set -euo pipefail

HOST="${ATOMOS_DEVICE_HOST:-127.0.0.1}"
USER="${ATOMOS_DEVICE_USER:-user}"
PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_OPTS=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" )

if [ -n "${ATOMOS_DEVICE_SSHPASS:-}" ]; then
  export SSHPASS="$ATOMOS_DEVICE_SSHPASS"
fi

if [ -n "${SSHPASS:-}" ]; then
  exec sshpass -e ssh "${SSH_OPTS[@]}" "$USER@$HOST" "$@"
fi

exec ssh "${SSH_OPTS[@]}" "$USER@$HOST" "$@"
