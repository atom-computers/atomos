#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"
AGENTS_SRC_DIR="$ROOT_DIR/../core/atomos-agents"
DIRECT_ROOTFS_DIR="${ROOTFS_DIR:-}"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

if [ "${PMOS_INSTALL_ATOMOS_AGENTS:-1}" = "0" ]; then
    echo "install-atomos-agents: skipped (PMOS_INSTALL_ATOMOS_AGENTS=0)"
    exit 0
fi

if [ ! -f "$AGENTS_SRC_DIR/src/server.py" ]; then
    echo "ERROR: atomos-agents source missing: $AGENTS_SRC_DIR/src/server.py" >&2
    exit 1
fi
if [ ! -f "$AGENTS_SRC_DIR/pyproject.toml" ]; then
    echo "ERROR: atomos-agents pyproject missing: $AGENTS_SRC_DIR/pyproject.toml" >&2
    exit 1
fi

install_direct_rootfs() {
    local root="$1"
    install -d "$root/opt/atomos"
    rm -rf "$root/opt/atomos/agents"
    install -d "$root/opt/atomos/agents"
    tar \
        --exclude='.venv*' \
        --exclude='__pycache__' \
        --exclude='.pytest_cache' \
        --exclude='*.pyc' \
        -C "$ROOT_DIR/../core" -cf - atomos-agents \
        | tar -xf - -C "$root/opt/atomos/agents" --strip-components=1
    rm -rf "$root/opt/atomos/agents/.deps"
    mkdir -p "$root/opt/atomos/agents/.deps"
    cat > "$root/usr/local/bin/atomos-agents-run" << "EOF"
#!/bin/sh
set -eu
cd /opt/atomos/agents/src
export PYTHONPATH="/opt/atomos/agents/.deps:/opt/atomos/agents/src"
exec /usr/bin/python3 /opt/atomos/agents/src/server.py
EOF
    chmod 755 "$root/usr/local/bin/atomos-agents-run"
    ln -sf ../local/bin/atomos-agents-run "$root/usr/bin/atomos-agents-run"
    install -d "$root/etc/systemd/system"
    cat > "$root/etc/systemd/system/atomos-agents.service" << "EOF"
[Unit]
Description=AtomOS Agents Service (gRPC bridge for applet clients)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/atomos/agents/src
Environment=PYTHONPATH=/opt/atomos/agents/src
Environment=PORT=50051
ExecStart=/usr/local/bin/atomos-agents-run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # OpenRC init script (the systemd unit above is inert under OpenRC).
    # Mirrors the systemd unit's behaviour: launches atomos-agents-run as
    # root in the background, supervised. respawn_max=5 caps the loop so
    # a misconfigured service doesn't pin the CPU forever -- this is
    # important because in --rootfs mode we install the source but DO
    # NOT pip-install dependencies (no live network in the cross-arch
    # build container). The user must run `pip install` on-device once
    # then `rc-update add atomos-agents default` to enable at boot.
    install -d "$root/etc/init.d"
    cat > "$root/etc/init.d/atomos-agents" << "EOF"
#!/sbin/openrc-run

description="AtomOS Agents Service (gRPC bridge for applet clients)"
supervisor=supervise-daemon
command=/usr/local/bin/atomos-agents-run
command_user=root
pidfile=/run/atomos-agents.pid
respawn_delay=5
respawn_max=5

depend() {
    need net
    after dbus
}
EOF
    chmod 0755 "$root/etc/init.d/atomos-agents"
    # Intentionally NOT linking into default runlevel -- on-device the
    # user must:
    #   1. install python deps:  cd /opt/atomos/agents && sudo pip install --break-system-packages .
    #   2. enable at boot:       sudo rc-update add atomos-agents default
    #   3. start now:            sudo rc-service atomos-agents start
}

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin" "$DIRECT_ROOTFS_DIR/usr/bin"
    install_direct_rootfs "$DIRECT_ROOTFS_DIR"
    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-agents-run"
    test -f "$DIRECT_ROOTFS_DIR/etc/systemd/system/atomos-agents.service"
    test -x "$DIRECT_ROOTFS_DIR/etc/init.d/atomos-agents"
    echo "Installed atomos-agents service (direct rootfs mode; systemd unit + OpenRC init script,"
    echo "  NOT enabled at boot -- enable on-device after pip-installing deps)."
    exit 0
fi

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    else
        PROFILE_ENV_ARG="$PROFILE_ENV_SOURCE"
    fi
fi

INSTALL_SCRIPT='
set -eu
apk update
if ! apk add --no-interactive --quiet python3 py3-pip ca-certificates git build-base libffi-dev openssl-dev >/dev/null 2>&1; then
    echo "WARN: dependency install failed; trying apk upgrade + retry..." >&2
    apk upgrade --no-interactive || true
    apk add --no-interactive python3 py3-pip ca-certificates git build-base libffi-dev openssl-dev
fi

mkdir -p /opt/atomos
rm -rf /opt/atomos/agents
mv /tmp/atomos-agents /opt/atomos/agents

rm -rf /opt/atomos/agents/.deps
mkdir -p /opt/atomos/agents/.deps
PIP_ROOT_USER_ACTION=ignore \
python3 -m pip install --break-system-packages --target /opt/atomos/agents/.deps /opt/atomos/agents

cat > /usr/local/bin/atomos-agents-run << "EOF"
#!/bin/sh
set -eu
cd /opt/atomos/agents/src
export PYTHONPATH="/opt/atomos/agents/.deps:/opt/atomos/agents/src"
exec /usr/bin/python3 /opt/atomos/agents/src/server.py
EOF
chmod 755 /usr/local/bin/atomos-agents-run
ln -sf /usr/local/bin/atomos-agents-run /usr/bin/atomos-agents-run

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/atomos-agents.service << "EOF"
[Unit]
Description=AtomOS Agents Service (gRPC bridge for applet clients)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/atomos/agents/src
Environment=PYTHONPATH=/opt/atomos/agents/src
Environment=PORT=50051
ExecStart=/usr/local/bin/atomos-agents-run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable atomos-agents.service >/dev/null 2>&1 || true
fi
'

if [ "${ATOMOS_INSTALL_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$INSTALL_SCRIPT"
    exit 0
fi

echo "Installing atomos-agents into rootfs for profile: ${PROFILE_NAME}"
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    tar \
        --exclude='.venv*' \
        --exclude='__pycache__' \
        --exclude='.pytest_cache' \
        --exclude='*.pyc' \
        -C "$ROOT_DIR/../core" -cf - atomos-agents \
        | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c \
            'rm -rf /tmp/atomos-agents && mkdir -p /tmp/atomos-agents && tar -xf - -C /tmp/atomos-agents --strip-components=1'
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_SCRIPT"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c \
        'test -x /usr/local/bin/atomos-agents-run && test -f /etc/systemd/system/atomos-agents.service'
else
    tar \
        --exclude='.venv*' \
        --exclude='__pycache__' \
        --exclude='.pytest_cache' \
        --exclude='*.pyc' \
        -C "$ROOT_DIR/../core" -cf - atomos-agents \
        | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c \
            'rm -rf /tmp/atomos-agents && mkdir -p /tmp/atomos-agents && tar -xf - -C /tmp/atomos-agents --strip-components=1'
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_SCRIPT"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c \
        'test -x /usr/local/bin/atomos-agents-run && test -f /etc/systemd/system/atomos-agents.service'
fi

echo "Installed atomos-agents service (port 50051) into rootfs."
