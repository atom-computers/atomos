# shellcheck shell=bash
# scripts/_lib-rootfs-users.sh -- create system + login users in the
# bootstrapped rootfs.
#
# This file owns the fix for the long-standing FP4 boot loop:
#
#     ERROR: user.greetd failed to start
#
# Root cause:
#   greetd's startup config (/etc/phrog/greetd-config.toml, with
#   user = "greetd" applied via vendor/aports/community/greetd/config.patch)
#   does setuid(getpwnam("greetd")). The greetd system user is created by
#   greetd's apk PRE-install script via busybox addgroup/adduser. Under
#   `apk --root /target add` running the pre-install via QEMU user-mode
#   emulation on macOS docker, busybox adduser's lckpwdf() against
#   /target/etc/.pwd.lock can return EAGAIN under heavy parallel
#   install, leaving the script as a silent no-op. apk reports this as
#   WARNING (not ERROR) and exits 0, so the build appears successful
#   while greetd lands without its system user.
#
# Fix strategy (defence in depth):
#
#   1. The bootstrap library FAILs the build if any apk
#      pre/post-install warning is reported (non-mkinitfs-trigger),
#      so we know immediately when the lockfile race kicks in.
#      (See _lib-rootfs-bootstrap.sh.)
#   2. Regardless of (1), this library re-creates every system user we
#      depend on by writing DIRECTLY to /target/etc/{passwd,group,shadow}
#      from a tiny container script (no busybox adduser, no qemu
#      binfmt-vs-flock race, no lockfile). Idempotent. The script body
#      lives in _lib-rootfs-users-body.sh.
#   3. After every creation we run `getent passwd <name>` from inside
#      chroot and assert. If it still misses we dump every relevant
#      file and exit non-zero so the next regression names itself.
#
# Required globals at call time:
#   ENGINE ALPINE_IMAGE ROOTFS_VOLUME ROOT_DIR PMOS_USER_UID INSTALL_PASSWORD

# Verify with `getent` from inside chroot that NAME resolves to a passwd
# AND group entry. Dumps the relevant files on failure.
atomos_user_assert_in_chroot() {
    local name="$1" label="$2"
    if "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "
            chroot /target /bin/sh -c \"getent passwd $name >/dev/null 2>&1 && getent group $name >/dev/null 2>&1\"
        "; then
        echo "  ASSERT[$label]: '$name' resolves via getent in chroot"
        return 0
    fi
    echo "  ASSERT[$label]: FAIL '$name' does NOT resolve via getent in chroot" >&2
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "
            echo '--- /target/etc/passwd grep ---' >&2
            grep -nE \"^${name}\\b|:${name}\\b\" /target/etc/passwd /target/etc/group /target/etc/shadow >&2 \
                || echo '(no matches)' >&2
            echo '--- chroot getent passwd $name ---' >&2
            chroot /target /bin/sh -c \"getent passwd $name\" >&2 || true
            echo '--- chroot getent group $name ---' >&2
            chroot /target /bin/sh -c \"getent group $name\" >&2 || true
        " >&2 || true
    return 1
}

# Standalone diagnostic for the user.greetd boot loop. Dumps:
#   - /etc/conf.d/greetd
#   - the cfgfile= it points at (typically /etc/phrog/greetd-config.toml)
#   - the user= field referenced by that config
#   - whether that user resolves via chroot getent
#   - the runlevel symlinks for greetd / seatd / elogind
atomos_user_diagnose_greetd() {
    local label="$1"
    echo "--- greetd diagnostic [$label] ---"
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c '
            cfgfile=""
            if [ -f /target/etc/conf.d/greetd ]; then
                echo "  /etc/conf.d/greetd:"
                sed "s/^/    /" /target/etc/conf.d/greetd
                cfgfile=$(awk -F= "/^[[:space:]]*cfgfile/{gsub(/[\"[:space:]]/,\"\",\$2); print \$2}" \
                    /target/etc/conf.d/greetd | head -1)
            else
                echo "  /etc/conf.d/greetd: MISSING"
            fi
            cfgfile=${cfgfile:-/etc/greetd/config.toml}
            target_cfg=/target${cfgfile}
            if [ -f "$target_cfg" ]; then
                echo "  $cfgfile:"
                sed "s/^/    /" "$target_cfg"
                session_user=$(awk -F"=" "/^[[:space:]]*user[[:space:]]*=/{gsub(/[\"[:space:]]/,\"\",\$2); print \$2; exit}" "$target_cfg")
                echo "  greetd session user (from config): \"$session_user\""
                if [ -n "$session_user" ]; then
                    if chroot /target /bin/sh -c "getent passwd $session_user" >/tmp/g 2>&1; then
                        sed "s/^/    /" /tmp/g
                    else
                        echo "    !! getent passwd $session_user FAILED -- this is the boot loop trigger" >&2
                    fi
                fi
            else
                echo "  $cfgfile: MISSING under /target"
            fi
            echo "  /etc/runlevels/default/ {greetd,seatd,elogind}:"
            for s in greetd seatd elogind; do
                p=/target/etc/runlevels/default/$s
                if [ -L "$p" ]; then
                    echo "    $s -> $(readlink "$p")"
                elif [ -e "$p" ]; then
                    echo "    $s (regular file)"
                else
                    echo "    $s MISSING" >&2
                fi
            done
        '
}

# The orchestrator's single entry point. Runs the in-container
# user-creation body file (which writes directly to
# /target/etc/{passwd,group,shadow}, no busybox adduser, no flock
# race), then verifies with getent in chroot.
atomos_ensure_system_users() {
    echo "=== build-fairphone4-v2: ensure system + login users (greetd fix) ==="

    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$ROOT_DIR/scripts/_lib-rootfs-users-body.sh:/lib-users-body.sh:ro" \
        -e PMOS_USER_UID="$PMOS_USER_UID" \
        -e INSTALL_PASSWORD="$INSTALL_PASSWORD" \
        "$ALPINE_IMAGE" /bin/sh /lib-users-body.sh

    echo "--- verifying users via getent in chroot ---"
    local fail=0
    atomos_user_assert_in_chroot greetd "post-create" || fail=1
    atomos_user_assert_in_chroot user    "post-create" || fail=1
    if [ "$fail" -ne 0 ]; then
        echo "FATAL: post-create getent assertion failed; refusing to continue." >&2
        atomos_user_diagnose_greetd "post-create-fail"
        exit 21
    fi
    atomos_user_diagnose_greetd "post-create"
}
