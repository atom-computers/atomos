#!/usr/bin/env bash
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
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

PHOSH_DIR="${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}"
if [ ! -d "$PHOSH_DIR" ]; then
    echo "ERROR: Phosh source tree not found: $PHOSH_DIR" >&2
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: $1 is required." >&2
        exit 1
    }
}

need_cmd ssh
need_cmd scp
need_cmd tar
need_cmd mktemp

SSH_CMD=(ssh)
SCP_CMD=(scp)
# Default to 22 (physical) or 2222 (virtual/QEMU forwards) if not already defined
if [ -z "${ATOMOS_DEVICE_SSH_PORT:-}" ]; then
    if [ "${PROFILE_NAME:-}" = "fairphone-fp4" ] || [ "${SSH_TARGET:-}" = "172.16.42.1" ] || [[ "${SSH_TARGET:-}" == *172.16.42.1* ]]; then
        export ATOMOS_DEVICE_SSH_PORT="22"
    else
        export ATOMOS_DEVICE_SSH_PORT="2222"
    fi
fi
SSH_PORT="${ATOMOS_DEVICE_SSH_PORT}"
if [ -n "${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}" ]; then
    need_cmd sshpass
    SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}"
    SSH_AUTH_OPTS=(
        -p "$SSH_PORT"
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        -o KbdInteractiveAuthentication=no
        -o NumberOfPasswordPrompts=1
    )
    SCP_AUTH_OPTS=(
        -P "$SSH_PORT"
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        -o KbdInteractiveAuthentication=no
        -o NumberOfPasswordPrompts=1
    )
    SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh "${SSH_AUTH_OPTS[@]}")
    SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp "${SCP_AUTH_OPTS[@]}")
else
    SSH_CMD=(ssh -p "$SSH_PORT")
    SCP_CMD=(scp -P "$SSH_PORT")
fi

REMOTE_TMP_DIR="${ATOMOS_PHOSH_REMOTE_TMP:-/tmp/atomos-phosh-hotfix.$$}"
REMOTE_SRC_DIR="${ATOMOS_PHOSH_REMOTE_SRC:-/usr/local/src/atomos-phosh}"
REMOTE_BUILD_DIR="${ATOMOS_PHOSH_REMOTE_BUILD_DIR:-$REMOTE_SRC_DIR/_build-atomos-hotfix}"
# greetd/phrog always exec /usr/libexec/phosh — prefix must be /usr or the
# hotfix builds successfully but the running session never changes.
REMOTE_PREFIX="${ATOMOS_PHOSH_REMOTE_PREFIX:-/usr}"
PHOSH_RUNTIME_BIN="${ATOMOS_PHOSH_RUNTIME_BIN:-/usr/libexec/phosh}"
# C string literal in home.c (ATOMOS_CHAT_SUBMIT_PATH); survives strip -O2.
# Legacy GtkBuilder ids (atomos-home-chat-entry) are not reliable: chat entry
# is created in code now and gresource blobs are often gzip-compressed.
PHOSH_VERIFY_MARKER="${ATOMOS_PHOSH_HOTFIX_VERIFY_MARKER:-atomos-overview-chat-submit}"
REMOTE_SUDO="${ATOMOS_PHOSH_REMOTE_SUDO:-sudo}"
REMOTE_SUDO_PASSWORD="${ATOMOS_PHOSH_REMOTE_SUDO_PASSWORD:-${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}}"
# Default behavior: restart phosh so newly installed bits are picked up.
# Override with ATOMOS_PHOSH_REMOTE_RESTART_CMD, or disable with empty string.
if [ "${ATOMOS_PHOSH_REMOTE_RESTART_CMD+set}" = "set" ]; then
    REMOTE_RESTART_CMD="$ATOMOS_PHOSH_REMOTE_RESTART_CMD"
else
    REMOTE_RESTART_CMD="__DEFAULT_RESTART_PHOSH__"
fi
PHOSH_SKIP_BUILD="${ATOMOS_PHOSH_HOTFIX_SKIP_BUILD:-0}"
# Fail fast by default: a hotfix should replace installed bits, not just sync source.
# Set ATOMOS_PHOSH_HOTFIX_SOURCE_ONLY_ON_BUILD_FAIL=1 to allow source-only fallback.
PHOSH_SOURCE_ONLY_ON_BUILD_FAIL="${ATOMOS_PHOSH_HOTFIX_SOURCE_ONLY_ON_BUILD_FAIL:-0}"
# Auto-install build deps on Alpine targets (postmarketOS) when meson/ninja or
# any phosh -dev package is missing. Set to 0 to require pre-baked deps.
PHOSH_INSTALL_BUILD_DEPS="${ATOMOS_PHOSH_HOTFIX_INSTALL_BUILD_DEPS:-1}"
# Wipe the remote Meson build dir before configure (avoids stale wrap cache /
# reconfigure state that can make Meson read corrupted subprojects/*.wrap).
PHOSH_CLEAN_BUILD="${ATOMOS_PHOSH_HOTFIX_CLEAN_BUILD:-1}"

echo "Phosh hotfix plan:"
echo "  host source:     $PHOSH_DIR"
echo "  remote src:      $REMOTE_SRC_DIR"
echo "  meson prefix:    $REMOTE_PREFIX"
echo "  install target:  ${REMOTE_PREFIX}/libexec/phosh"
echo "  runtime binary:  $PHOSH_RUNTIME_BIN (what greetd/phrog exec)"
if [ "$REMOTE_PREFIX" != "/usr" ]; then
    echo "WARN: REMOTE_PREFIX is not /usr — the session will keep using $PHOSH_RUNTIME_BIN" >&2
    echo "      unless you change greetd to launch ${REMOTE_PREFIX}/libexec/phosh." >&2
fi

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

ARCHIVE_PATH="$tmpdir/phosh-src.tar.gz"
# macOS tar embeds AppleDouble/xattrs unless disabled; those can land beside
# subprojects/*.wrap on Linux and break Meson's UTF-8 wrap parser.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    export COPYFILE_DISABLE=1
fi
(
    cd "$PHOSH_DIR"
    tar -czf "$ARCHIVE_PATH" \
        --exclude-vcs \
        --exclude "_build*" \
        --exclude "build" \
        --exclude ".direnv" \
        --exclude "subprojects/packagecache" \
        --exclude "subprojects/packagefiles" \
        --exclude "*.o" \
        --exclude "*.so" \
        --exclude "*.a" \
        --exclude "._*" \
        .
)

echo "Uploading phosh source snapshot to $SSH_TARGET:$REMOTE_TMP_DIR ..."
"${SSH_CMD[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_TMP_DIR'"
"${SCP_CMD[@]}" "$ARCHIVE_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/phosh-src.tar.gz"

shell_quote_sq() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

REMOTE_TMP_DIR_Q="$(shell_quote_sq "$REMOTE_TMP_DIR")"
REMOTE_SRC_DIR_Q="$(shell_quote_sq "$REMOTE_SRC_DIR")"
REMOTE_BUILD_DIR_Q="$(shell_quote_sq "$REMOTE_BUILD_DIR")"
REMOTE_PREFIX_Q="$(shell_quote_sq "$REMOTE_PREFIX")"
REMOTE_RESTART_CMD_Q="$(shell_quote_sq "$REMOTE_RESTART_CMD")"
PHOSH_SKIP_BUILD_Q="$(shell_quote_sq "$PHOSH_SKIP_BUILD")"
PHOSH_SOURCE_ONLY_ON_BUILD_FAIL_Q="$(shell_quote_sq "$PHOSH_SOURCE_ONLY_ON_BUILD_FAIL")"
PHOSH_INSTALL_BUILD_DEPS_Q="$(shell_quote_sq "$PHOSH_INSTALL_BUILD_DEPS")"
PHOSH_CLEAN_BUILD_Q="$(shell_quote_sq "$PHOSH_CLEAN_BUILD")"
PHOSH_RUNTIME_BIN_Q="$(shell_quote_sq "$PHOSH_RUNTIME_BIN")"
PHOSH_VERIFY_MARKER_Q="$(shell_quote_sq "$PHOSH_VERIFY_MARKER")"

REMOTE_APPLY_SCRIPT="$(cat <<EOF
set -eu
REMOTE_TMP_DIR=$REMOTE_TMP_DIR_Q
REMOTE_SRC_DIR=$REMOTE_SRC_DIR_Q
REMOTE_BUILD_DIR=$REMOTE_BUILD_DIR_Q
REMOTE_PREFIX=$REMOTE_PREFIX_Q
REMOTE_RESTART_CMD=$REMOTE_RESTART_CMD_Q
PHOSH_SKIP_BUILD=$PHOSH_SKIP_BUILD_Q
PHOSH_SOURCE_ONLY_ON_BUILD_FAIL=$PHOSH_SOURCE_ONLY_ON_BUILD_FAIL_Q
PHOSH_INSTALL_BUILD_DEPS=$PHOSH_INSTALL_BUILD_DEPS_Q
PHOSH_CLEAN_BUILD=$PHOSH_CLEAN_BUILD_Q
PHOSH_RUNTIME_BIN=$PHOSH_RUNTIME_BIN_Q
PHOSH_VERIFY_MARKER=$PHOSH_VERIFY_MARKER_Q
HOTFIX_INSTALLED=0
PHOSH_INSTALLED_BIN="\${REMOTE_PREFIX}/libexec/phosh"

verify_subproject_wraps() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARN: python3 missing; skipping subprojects/*.wrap UTF-8 check" >&2
        return 0
    fi
    python3 - "\$REMOTE_SRC_DIR/subprojects" <<'PY'
import os
import sys

root = sys.argv[1]
if not os.path.isdir(root):
    sys.exit(0)

bad = []
for name in sorted(os.listdir(root)):
    if not name.endswith(".wrap"):
        continue
    path = os.path.join(root, name)
    try:
        with open(path, encoding="utf-8") as fh:
            fh.read()
    except UnicodeDecodeError as exc:
        bad.append((path, exc))

if bad:
    for path, exc in bad:
        print(f"ERROR: invalid UTF-8 in {path}: {exc}", file=sys.stderr)
        try:
            with open(path, "rb") as fh:
                sample = fh.read(80)
            print(f"  first bytes: {sample!r}", file=sys.stderr)
        except OSError:
            pass
    sys.exit(1)
PY
}

# Mirrors build-qemu.sh's container apk list so an on-device build sees the
# same package set the cached host build resolves against. Keep this list in
# sync with the apk add stanza in scripts/build-qemu.sh; phosh's meson.build
# is the source of truth for the dependency set.
PHOSH_BUILD_DEPS="\
build-base git meson ninja-build pkgconf \
glib-dev gtk+3.0-dev libhandy1-dev \
gnome-bluetooth-dev gnome-desktop-dev libgudev-dev \
evolution-data-server-dev gcr-dev libsecret-dev \
callaudiod-dev feedbackd-dev pulseaudio-dev \
networkmanager-dev modemmanager-dev upower-dev \
evince-dev qrcodegen-dev polkit-dev elogind-dev \
gobject-introspection-dev vala \
wayland-dev wayland-protocols \
libxkbcommon-dev dbus-dev linux-pam-dev \
pango-dev cairo-dev gdk-pixbuf-dev libsoup3-dev json-glib-dev \
appstream-dev fribidi-dev desktop-file-utils gstreamer-dev \
"

ensure_build_deps() {
    [ "\$PHOSH_INSTALL_BUILD_DEPS" = "1" ] || return 0
    if ! command -v apk >/dev/null 2>&1; then
        # Non-Alpine target: leave dep handling to the operator.
        return 0
    fi
    # Skip the (slow) apk solve if the toolchain entrypoints are already there.
    # First-time hotfix on a clean rootfs will hit the install path; subsequent
    # runs short-circuit here.
    if command -v meson >/dev/null 2>&1 \
       && command -v ninja >/dev/null 2>&1 \
       && command -v pkg-config >/dev/null 2>&1; then
        return 0
    fi
    echo "Installing phosh build deps via apk (one-time per device)..."
    # --no-interactive: never prompt; missing packages cause a non-zero exit.
    # Spread the list across one apk invocation so the solver can pick a
    # consistent edge/community set in a single transaction.
    # shellcheck disable=SC2086
    if ! apk add --no-interactive \$PHOSH_BUILD_DEPS; then
        echo "WARN: apk add failed for one or more phosh build deps." >&2
        echo "      You can disable auto-install with ATOMOS_PHOSH_HOTFIX_INSTALL_BUILD_DEPS=0" >&2
        echo "      and pre-bake the deps via PMOS_EXTRA_PACKAGES in your profile env." >&2
        return 1
    fi
    return 0
}

running_phosh_exe() {
    local pid exe
    pid=\$(pidof phosh 2>/dev/null | awk '{print \$1}')
    if [ -z "\$pid" ]; then
        pid=\$(pgrep -x phosh 2>/dev/null | head -n1)
    fi
    [ -n "\$pid" ] || return 1
    exe=\$(readlink -f "/proc/\$pid/exe" 2>/dev/null || true)
    [ -n "\$exe" ] || return 1
    printf '%s\n' "\$exe"
}

phosh_binary_has_atomos_marker() {
    local bin="\$1"
    local m
    for m in "\$PHOSH_VERIFY_MARKER" atomos-overview-chat-submit "Ask AtomOS"; do
        if strings "\$bin" 2>/dev/null | grep -q "\$m"; then
            PHOSH_DETECTED_MARKER="\$m"
            return 0
        fi
    done
    return 1
}

verify_phosh_install() {
    if [ ! -x "\$PHOSH_INSTALLED_BIN" ]; then
        echo "ERROR: meson install did not produce executable: \$PHOSH_INSTALLED_BIN" >&2
        exit 1
    fi
    if ! phosh_binary_has_atomos_marker "\$PHOSH_INSTALLED_BIN"; then
        echo "ERROR: \$PHOSH_INSTALLED_BIN lacks AtomOS marker (tried: \$PHOSH_VERIFY_MARKER, atomos-overview-chat-submit, Ask AtomOS)." >&2
        echo "       The build may have used the wrong source tree or install prefix." >&2
        exit 1
    fi
    echo "Verified install: \$PHOSH_INSTALLED_BIN (marker: \$PHOSH_DETECTED_MARKER)"
    if [ "\$PHOSH_INSTALLED_BIN" != "\$PHOSH_RUNTIME_BIN" ]; then
        echo "ERROR: install path \$PHOSH_INSTALLED_BIN != runtime \$PHOSH_RUNTIME_BIN." >&2
        echo "       Set ATOMOS_PHOSH_REMOTE_PREFIX=/usr (default) so greetd loads the hotfix." >&2
        exit 1
    fi
}

verify_running_phosh() {
    local exe
    exe=\$(running_phosh_exe || true)
    if [ -z "\$exe" ]; then
        echo "WARN: no running phosh process after restart (session may still be starting)." >&2
        return 0
    fi
    echo "Running phosh: \$exe"
    if [ "\$exe" != "\$PHOSH_RUNTIME_BIN" ]; then
        echo "ERROR: running phosh is '\$exe', expected '\$PHOSH_RUNTIME_BIN'." >&2
        echo "       Hotfix binary was installed but the session is still using another build." >&2
        exit 1
    fi
    if ! phosh_binary_has_atomos_marker "\$exe"; then
        echo "ERROR: running phosh lacks AtomOS marker — stale binary still in use." >&2
        exit 1
    fi
    echo "Running phosh marker: \$PHOSH_DETECTED_MARKER"
}

restart_phosh_default() {
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/greetd ]; then
        echo "Restarting greetd (reloads \$PHOSH_RUNTIME_BIN)..."
        if rc-service greetd restart; then
            sleep 2
            verify_running_phosh
            return 0
        fi
        echo "WARN: rc-service greetd restart failed; falling back to kill phosh." >&2
    fi

    pids=\$(pidof phosh 2>/dev/null || true)
    if [ -z "\$pids" ]; then
        pids=\$(pgrep -x phosh 2>/dev/null || true)
    fi
    if [ -z "\$pids" ]; then
        echo "No running phosh process found to restart."
        return 0
    fi

    echo "Restarting phosh (pids: \$pids)"
    kill -TERM \$pids 2>/dev/null || true
    sleep 2
    for pid in \$pids; do
        kill -0 "\$pid" 2>/dev/null || continue
        kill -KILL "\$pid" 2>/dev/null || true
    done
    sleep 1
    verify_running_phosh
}

mkdir -p "\$REMOTE_TMP_DIR/unpack"
tar -xzf "\$REMOTE_TMP_DIR/phosh-src.tar.gz" -C "\$REMOTE_TMP_DIR/unpack"

rm -rf "\$REMOTE_SRC_DIR"
mkdir -p "\$REMOTE_SRC_DIR"
cp -a "\$REMOTE_TMP_DIR/unpack/." "\$REMOTE_SRC_DIR/"

echo "Phosh source synced to \$REMOTE_SRC_DIR"

# Drop Meson wrap cache dirs that may linger from a previous on-device build.
rm -rf "\$REMOTE_SRC_DIR/subprojects/packagecache" \
       "\$REMOTE_SRC_DIR/subprojects/packagefiles"
find "\$REMOTE_SRC_DIR/subprojects" -name '._*.wrap' -delete 2>/dev/null || true

if ! verify_subproject_wraps; then
    echo "ERROR: subprojects/*.wrap files are not valid UTF-8 (see bytes above)." >&2
    echo "       Re-run from a clean host tree or set ATOMOS_PHOSH_HOTFIX_CLEAN_BUILD=1." >&2
    exit 1
fi

if [ "\$PHOSH_SKIP_BUILD" = "1" ]; then
    echo "Skipping remote build/install (ATOMOS_PHOSH_HOTFIX_SKIP_BUILD=1)"
else
    if ! ensure_build_deps; then
        echo "WARN: could not install all phosh build deps via apk." >&2
    fi
    if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
        if [ "\$PHOSH_SOURCE_ONLY_ON_BUILD_FAIL" = "1" ]; then
            echo "WARN: meson/ninja missing on target, source-only sync applied." >&2
        else
            echo "ERROR: meson and ninja are required on target for build/install." >&2
            echo "       Auto-install was attempted via apk; check the WARN above." >&2
            echo "       To pre-bake deps into the rootfs add 'meson,ninja-build' (and the" >&2
            echo "       phosh -dev packages from scripts/phosh/hotfix-phosh.sh) to" >&2
            echo "       PMOS_EXTRA_PACKAGES in your profile env, then reflash." >&2
            exit 1
        fi
    else
        if [ "\$PHOSH_CLEAN_BUILD" = "1" ] && [ -d "\$REMOTE_BUILD_DIR" ]; then
            echo "Removing stale Meson build dir: \$REMOTE_BUILD_DIR"
            rm -rf "\$REMOTE_BUILD_DIR"
        fi
        if [ -d "\$REMOTE_BUILD_DIR" ]; then
            meson setup --reconfigure "\$REMOTE_BUILD_DIR" "\$REMOTE_SRC_DIR" \
                --prefix "\$REMOTE_PREFIX" \
                -Dtests=false
        else
            meson setup "\$REMOTE_BUILD_DIR" "\$REMOTE_SRC_DIR" \
                --prefix "\$REMOTE_PREFIX" \
                -Dtests=false
        fi
        if meson compile -C "\$REMOTE_BUILD_DIR" && meson install -C "\$REMOTE_BUILD_DIR"; then
            echo "Remote phosh build/install completed."
            verify_phosh_install
            HOTFIX_INSTALLED=1
        else
            echo "ERROR: meson compile or meson install failed." >&2
            if [ "\$PHOSH_SOURCE_ONLY_ON_BUILD_FAIL" = "1" ]; then
                echo "WARN: remote build failed, source-only sync applied." >&2
            else
                exit 1
            fi
        fi
    fi
fi

if [ "\$HOTFIX_INSTALLED" = "1" ] && [ -n "\$REMOTE_RESTART_CMD" ]; then
    echo "Running phosh restart command..."
    if [ "\$REMOTE_RESTART_CMD" = "__DEFAULT_RESTART_PHOSH__" ]; then
        restart_phosh_default
    else
        /bin/sh -eu -c "\$REMOTE_RESTART_CMD"
    fi
elif [ "\$HOTFIX_INSTALLED" != "1" ]; then
    echo "Skipping phosh restart because no build/install completed." >&2
    if [ "\$PHOSH_SKIP_BUILD" = "1" ] || [ "\$PHOSH_SOURCE_ONLY_ON_BUILD_FAIL" = "1" ]; then
        echo "WARN: source-only hotfix — \$PHOSH_RUNTIME_BIN was NOT updated." >&2
    else
        echo "ERROR: hotfix did not install \$PHOSH_RUNTIME_BIN (source was synced only)." >&2
        exit 1
    fi
fi

rm -rf "\$REMOTE_TMP_DIR"
EOF
)"

REMOTE_APPLY_BASENAME="atomos-phosh-hotfix-apply.sh"
REMOTE_APPLY_PATH="$tmpdir/$REMOTE_APPLY_BASENAME"
printf '%s\n' "$REMOTE_APPLY_SCRIPT" > "$REMOTE_APPLY_PATH"
chmod 700 "$REMOTE_APPLY_PATH"

"${SCP_CMD[@]}" "$REMOTE_APPLY_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME"

echo "Applying remote phosh hotfix..."
apply_rc=0
if [ -n "$REMOTE_SUDO" ]; then
    # Some targets enforce requiretty in sudoers. Force a TTY for sudo steps.
    if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
        "${SSH_CMD[@]}" -tt "$SSH_TARGET" "printf '%s\n' $(shell_quote_sq "$REMOTE_SUDO_PASSWORD") | $REMOTE_SUDO -S -p '' -k -- /bin/sh -eu '$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME'" || apply_rc=$?
    else
        "${SSH_CMD[@]}" -tt "$SSH_TARGET" "$REMOTE_SUDO" -- /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME" || apply_rc=$?
    fi
else
    "${SSH_CMD[@]}" "$SSH_TARGET" /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME" || apply_rc=$?
fi

if [ "$apply_rc" -ne 0 ]; then
    echo "ERROR: remote hotfix apply failed (exit $apply_rc)." >&2
    echo "  If sudo enforces a TTY, this script now requests one with ssh -tt." >&2
    echo "  If sudo password differs from SSH password, set:" >&2
    echo "  ATOMOS_PHOSH_REMOTE_SUDO_PASSWORD='<actual-sudo-password>'" >&2
    exit "$apply_rc"
fi

echo "Phosh hotfix applied: $PHOSH_RUNTIME_BIN updated from $PHOSH_DIR"
