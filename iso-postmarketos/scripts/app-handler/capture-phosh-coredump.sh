#!/bin/bash
# Capture a core dump from the post-login Phosh SIGSEGV and print a backtrace.
#
# Pairs with bisect-phosh-runtime-knobs.sh: once that confirms the SIGSEGV
# is in an always-on AtomOS-patched phosh path, run this to learn which
# function actually faults so we know which patch to revert.
#
# Procedure on the device (over SSH, via doas / sudo / expect):
#   1. Enable core dumps: kernel.core_pattern = /tmp/core-%e-%p-%t,
#      fs.suid_dumpable = 2, RLIMIT_CORE = unlimited for greetd's child
#      session (we set it on greetd's openrc unit so phosh inherits it).
#   2. Best-effort apk add gdb + libphosh-dbg / phosh-dbg if available.
#   3. Clear any pre-existing /tmp/core-phosh-*.
#   4. Restart greetd. Phosh boots, segfaults, kernel writes /tmp/core-*.
#   5. Poll for /tmp/core-phosh-* for WAIT_SECONDS (default 30s).
#   6. Run gdb --batch with `info threads`, `bt 50`, `bt full` on the most
#      recent core.
#   7. Pull the dmesg "phosh[NNNN] segfault at <addr> ip <addr>" line too —
#      that gives the faulting instruction pointer for cross-checking.
#   8. Optional: scp the core back to the host for offline analysis.
#
# Usage:
#   ATOMOS_DEVICE_SSH_PORT=2222 \
#   bash iso-postmarketos/scripts/app-handler/capture-phosh-coredump.sh \
#     iso-postmarketos/config/arm64-virt.env user@localhost
#
# Env knobs:
#   ATOMOS_COREDUMP_WAIT_SECONDS   poll window for the new core (default 30)
#   ATOMOS_COREDUMP_FETCH          scp the core file back (default 0; size!)
#   ATOMOS_COREDUMP_FETCH_DIR      local dir for the fetched core (default build/qemu-coredumps)
#   ATOMOS_DEVICE_SSH_PORT, ATOMOS_DEVICE_SSHPASS — same as other scripts
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
# shellcheck source=/dev/null
[ -f "$PROFILE_ENV_SOURCE" ] && source "$PROFILE_ENV_SOURCE"

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
WAIT_SECONDS="${ATOMOS_COREDUMP_WAIT_SECONDS:-30}"
FETCH_CORE="${ATOMOS_COREDUMP_FETCH:-0}"
FETCH_DIR="${ATOMOS_COREDUMP_FETCH_DIR:-$ROOT_DIR/build/qemu-coredumps}"

export ATOMOS_DEVICE_SSH_PORT="$SSH_PORT"
REMOTE_SUDO_PASSWORD="$SSH_PASSWORD"
export REMOTE_SUDO_PASSWORD

SSH_OPTS=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" "${SSH_OPTS[@]}")
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" "${SSH_OPTS[@]}")

# shellcheck source=_lib-remote-elevate.sh
source "$ROOT_DIR/scripts/app-handler/_lib-remote-elevate.sh"

echo "capture-phosh-coredump: $SSH_TARGET (port $SSH_PORT)"
echo "  wait window: ${WAIT_SECONDS}s   fetch core: ${FETCH_CORE}"

# ── Phase 1: enable core dumps + clear stale + restart greetd ────────────
echo ""
echo "=== Enable core dumps + restart greetd ==="

PREP_BODY=$(cat <<'PREP_EOF'
set -eu

# Kernel core pattern: dump into /tmp with the executable, pid and epoch.
# Falls back gracefully on kernels that disallow the path setting.
echo "/tmp/core-%e-%p-%t" > /proc/sys/kernel/core_pattern 2>/dev/null \
    || echo "WARN: could not set core_pattern" >&2
echo 2 > /proc/sys/fs/suid_dumpable 2>/dev/null || true
echo 1 > /proc/sys/kernel/core_uses_pid 2>/dev/null || true

# Lift the per-process core limit globally. systemd-less Alpine: edit /etc/security/limits.conf
# AND set on the greetd OpenRC unit so the child session inherits it.
if ! grep -qE '^\*\s+soft\s+core\s+unlimited' /etc/security/limits.conf 2>/dev/null; then
    {
        echo "* soft core unlimited"
        echo "* hard core unlimited"
    } >> /etc/security/limits.conf
fi

# OpenRC: drop a conf.d override so /etc/init.d/greetd's child process group
# gets RLIMIT_CORE=unlimited. /etc/conf.d/greetd is sourced by the initscript.
if [ -f /etc/conf.d/greetd ] && ! grep -qF 'rc_ulimit="-c unlimited"' /etc/conf.d/greetd; then
    echo 'rc_ulimit="-c unlimited"' >> /etc/conf.d/greetd
fi

# Make sure /tmp is large enough; a phosh core is typically 50-200 MB.
df -h /tmp | head -n 2

# Clear stale cores so the next /tmp/core-phosh-* is the one we want.
rm -f /tmp/core-phosh-* /tmp/core-phoc-* /tmp/core-gnome-session-* 2>/dev/null || true

# Install gdb + (if present) phosh/libphosh debug symbols. apk -e fails
# silently on Alpine if -dbg subpackages aren't built; we ignore errors.
if ! command -v gdb >/dev/null 2>&1; then
    apk add --no-interactive gdb 2>&1 | tail -n 3 || true
fi
for sym in phosh-dbg libphosh-dbg phosh-debug libphosh-debug elfutils; do
    apk add --no-interactive "$sym" 2>/dev/null | tail -n 1 || true
done

# Restart greetd so phosh boots fresh with the new ulimit + core_pattern.
if command -v rc-service >/dev/null 2>&1; then
    rc-service greetd restart 2>&1 | head -n 3
elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart greetd 2>&1 | head -n 3
else
    echo "WARN: no rc-service / systemctl; greetd not restarted" >&2
fi

# Note for the host-side script: we exit normally so caller proceeds.
PREP_EOF
)

if ! atomos_remote_run_elevated "$SSH_TARGET" "$PREP_BODY"; then
    echo "FAIL  cannot enable core dumps (elevation failed)" >&2
    exit 1
fi

# ── Phase 2: poll for the new core file ─────────────────────────────────
echo ""
echo "=== Wait for phosh to crash + drop a core (${WAIT_SECONDS}s) ==="

POLL_BODY=$(cat <<'POLL_EOF'
set -u
WAIT_SECONDS=__WAIT_SECONDS__
waited=0
core=""
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    # Pick the freshest /tmp/core-phosh-* OR /tmp/core-phosh.real-* (post-strip wrapper).
    core="$(ls -1t /tmp/core-phosh* 2>/dev/null | head -n 1 || true)"
    if [ -n "$core" ] && [ -s "$core" ]; then
        printf 'core: %s (%s bytes, t+%ds)\n' "$core" "$(stat -c '%s' "$core" 2>/dev/null || echo ?)" "$waited"
        echo "$core" > /tmp/.atomos-bisect-core-path
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done
echo "no core dumped within ${WAIT_SECONDS}s; try increasing ATOMOS_COREDUMP_WAIT_SECONDS"
echo "  /tmp listing for diagnosis:"
ls -lt /tmp 2>/dev/null | head -n 20 | sed 's/^/    /'
exit 2
POLL_EOF
)
POLL_BODY="${POLL_BODY//__WAIT_SECONDS__/$WAIT_SECONDS}"

if ! "${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<<"$POLL_BODY"; then
    echo "FAIL  no core file appeared — see /tmp listing above" >&2
    echo "  Re-run, or capture by hand:" >&2
    echo "    ssh -tt -p $SSH_PORT $SSH_TARGET 'doas tail -F /var/log/messages'" >&2
    exit 1
fi

# ── Phase 3: backtrace via gdb on the device ────────────────────────────
echo ""
echo "=== gdb backtrace on device ==="

BT_BODY=$(cat <<'BT_EOF'
set -u
core="$(cat /tmp/.atomos-bisect-core-path 2>/dev/null || true)"
if [ -z "$core" ] || [ ! -s "$core" ]; then
    echo "no core path recorded — aborting" >&2
    exit 1
fi

# Pick the phosh executable that produced the core. Pattern is
# /tmp/core-<exe>-<pid>-<time> per core_pattern above.
exe_base="$(basename "$core" | awk -F- '{print $2}')"
exe="/usr/libexec/$exe_base"
[ -x "$exe" ] || exe="/usr/bin/$exe_base"
[ -x "$exe" ] || exe="$(command -v "$exe_base" 2>/dev/null || true)"

echo "binary: $exe"
echo "core:   $core"

if ! command -v gdb >/dev/null 2>&1; then
    echo "WARN: gdb not installed; skipping backtrace" >&2
    echo "  install: doas apk add gdb"
    exit 0
fi

gdb --batch --quiet \
    -ex 'set pagination off' \
    -ex 'set print frame-arguments all' \
    -ex 'set print frame-info source-and-location' \
    -ex 'thread apply all bt 30' \
    -ex 'info threads' \
    -ex 'bt 60' \
    -ex 'bt full' \
    "$exe" "$core" 2>&1 | sed 's/^/    /'
BT_EOF
)

"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<<"$BT_BODY"

# ── Phase 4: dmesg segfault line (faulting IP) ──────────────────────────
echo ""
echo "=== dmesg segfault marker ==="
"${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -u" <<'DMESG_EOF'
if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | tail -n 300 | grep -E 'phosh.*segfault|phosh.*SIGSEGV|traps: phosh|trap_no=14' | tail -n 5 \
        || echo "INFO  no phosh segfault marker in last 300 dmesg lines"
else
    echo "INFO  dmesg not available"
fi
DMESG_EOF

# ── Phase 5: optional fetch ─────────────────────────────────────────────
if [ "$FETCH_CORE" = "1" ]; then
    echo ""
    echo "=== Fetch core to host ==="
    mkdir -p "$FETCH_DIR"
    REMOTE_CORE_PATH="$("${SSH_CMD[@]}" "$SSH_TARGET" "cat /tmp/.atomos-bisect-core-path 2>/dev/null" || true)"
    if [ -n "$REMOTE_CORE_PATH" ]; then
        LOCAL_CORE_PATH="$FETCH_DIR/$(basename "$REMOTE_CORE_PATH")"
        # Cores may not be readable by the SSH user; chmod via doas first.
        atomos_remote_run_elevated "$SSH_TARGET" "chmod 0644 '$REMOTE_CORE_PATH' || true" || true
        "${SCP_CMD[@]}" "$SSH_TARGET:$REMOTE_CORE_PATH" "$LOCAL_CORE_PATH"
        echo "fetched: $LOCAL_CORE_PATH ($(stat -f '%z' "$LOCAL_CORE_PATH" 2>/dev/null || stat -c '%s' "$LOCAL_CORE_PATH" 2>/dev/null) bytes)"
    else
        echo "WARN: no remote core path recorded; nothing to fetch"
    fi
fi
