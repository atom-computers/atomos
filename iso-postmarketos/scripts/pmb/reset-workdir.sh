#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <work-dir>" >&2
    exit 1
fi

# Trailing slash would break prefix checks below.
WORK_DIR="${1%/}"
if [ ! -e "$WORK_DIR" ]; then
    exit 0
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# Walk ancestors of WORK_DIR; if any path is on virtiofs / 9p / FUSE, aggressive
# umount -lf under the work dir can detach the whole shared mount and break the
# checkout with "Transport endpoint is not connected" (common on Multipass /
# virtiofs home directories).
# ATOMOS_RESET_WORKDIR_UMOUNT: unset or "auto" = decide from fstype; "1"/"yes"/"force" = always umount; "0"/"no"/"skip" = never umount.
should_skip_umount() {
    local d fst
    d="$WORK_DIR"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        fst="$(findmnt -n -o FSTYPE "$d" 2>/dev/null || true)"
        case "$fst" in
            virtiofs | 9p | vboxsf | vmhgfs | fuse | fuse* | fuseblk)
                return 0
                ;;
        esac
        d="$(dirname "$d")"
    done
    return 1
}

do_umount_loop=0
case "${ATOMOS_RESET_WORKDIR_UMOUNT:-auto}" in
    1 | yes | true | force)
        do_umount_loop=1
        ;;
    0 | no | false | skip)
        do_umount_loop=0
        ;;
    auto | "")
        if should_skip_umount; then
            echo "reset-workdir: skipping umount (work dir is under virtiofs/FUSE/9p — avoids breaking VM shared folders). Set ATOMOS_RESET_WORKDIR_UMOUNT=1 to force umount on local disk only." >&2
            do_umount_loop=0
        else
            do_umount_loop=1
        fi
        ;;
    *)
        echo "ERROR: ATOMOS_RESET_WORKDIR_UMOUNT must be auto, 0, or 1 (got ${ATOMOS_RESET_WORKDIR_UMOUNT})" >&2
        exit 2
        ;;
esac

# Unmount everything rooted under WORK_DIR, deepest paths first.
# IMPORTANT: Do not use awk regex on WORK_DIR — paths contain "." which would
# match any character and can wrongly match unrelated mounts (e.g.
# .atomos-pmbootstrap-work vs .../atomos/...). Wrong umounts break virtiofs/FUSE
# and produce "Transport endpoint is not connected" for the project tree.
TMP_MOUNTS="$(mktemp)"
cleanup_tmp() {
    rm -f "$TMP_MOUNTS"
}
trap cleanup_tmp EXIT

if [ "$do_umount_loop" = "1" ]; then
    : > "$TMP_MOUNTS"
    if command -v findmnt >/dev/null 2>&1; then
        while IFS= read -r mp; do
            [ -n "$mp" ] || continue
            if [[ "$mp" == "$WORK_DIR" || "$mp" == "$WORK_DIR"/* ]]; then
                printf '%s\n' "$mp" >> "$TMP_MOUNTS"
            fi
        done < <(findmnt -n -r -o TARGET 2>/dev/null || true)
    elif command -v mount >/dev/null 2>&1; then
        # "device on /mountpoint type fstype ..."
        while IFS= read -r line; do
            case "$line" in
                *" on "*)
                    rest="${line#* on }"
                    mp="${rest%% type *}"
                    mp="${mp%% (*}"
                    ;;
                *) continue ;;
            esac
            [ -n "$mp" ] || continue
            if [[ "$mp" == "$WORK_DIR" || "$mp" == "$WORK_DIR"/* ]]; then
                printf '%s\n' "$mp" >> "$TMP_MOUNTS"
            fi
        done < <(mount 2>/dev/null || true)
    fi

    sort -ru -o "$TMP_MOUNTS" "$TMP_MOUNTS" 2>/dev/null || true

    while IFS= read -r MP; do
        [ -n "$MP" ] || continue
        $SUDO umount -lf "$MP" >/dev/null 2>&1 || true
    done < "$TMP_MOUNTS"
fi

if ! $SUDO rm -rf "$WORK_DIR"; then
    echo "reset-workdir: rm -rf failed (busy mounts?). Try: reboot, or pmbootstrap zap, or ATOMOS_RESET_WORKDIR_UMOUNT=1 on a local ext4 work path." >&2
    exit 1
fi
