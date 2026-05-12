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
SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
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
REMOTE_PREFIX="${ATOMOS_PHOSH_REMOTE_PREFIX:-/usr/local}"
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

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

ARCHIVE_PATH="$tmpdir/phosh-src.tar.gz"
(
    cd "$PHOSH_DIR"
    tar -czf "$ARCHIVE_PATH" \
        --exclude-vcs \
        --exclude "_build*" \
        --exclude "build" \
        --exclude ".direnv" \
        --exclude "*.o" \
        --exclude "*.so" \
        --exclude "*.a" \
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
HOTFIX_INSTALLED=0

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

restart_phosh_default() {
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
    sleep 1
    # If any process survived TERM, hard-kill.
    for pid in \$pids; do
        kill -0 "\$pid" 2>/dev/null || continue
        kill -KILL "\$pid" 2>/dev/null || true
    done
}

mkdir -p "\$REMOTE_TMP_DIR/unpack"
tar -xzf "\$REMOTE_TMP_DIR/phosh-src.tar.gz" -C "\$REMOTE_TMP_DIR/unpack"

rm -rf "\$REMOTE_SRC_DIR"
mkdir -p "\$REMOTE_SRC_DIR"
cp -a "\$REMOTE_TMP_DIR/unpack/." "\$REMOTE_SRC_DIR/"

echo "Phosh source synced to \$REMOTE_SRC_DIR"

if [ "\$PHOSH_SKIP_BUILD" = "1" ]; then
    echo "Skipping remote build/install (ATOMOS_PHOSH_HOTFIX_SKIP_BUILD=1)"
else
    ensure_build_deps || true
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
        if [ -d "\$REMOTE_BUILD_DIR" ]; then
            meson setup --reconfigure "\$REMOTE_BUILD_DIR" "\$REMOTE_SRC_DIR" --prefix "\$REMOTE_PREFIX"
        else
            meson setup "\$REMOTE_BUILD_DIR" "\$REMOTE_SRC_DIR" --prefix "\$REMOTE_PREFIX"
        fi
        if meson compile -C "\$REMOTE_BUILD_DIR" && meson install -C "\$REMOTE_BUILD_DIR"; then
            echo "Remote phosh build/install completed."
            HOTFIX_INSTALLED=1
        else
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
elif [ "\$HOTFIX_INSTALLED" != "1" ] && [ -n "\$REMOTE_RESTART_CMD" ]; then
    echo "Skipping phosh restart because no build/install completed."
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

echo "Phosh hotfix applied."
