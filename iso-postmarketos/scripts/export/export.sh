#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <build-dir>" >&2
    exit 1
fi

PROFILE_ENV="$1"
BUILD_DIR="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"

# shellcheck source=/dev/null
source "$PROFILE_ENV"

EXPORT_DIR="$BUILD_DIR/export-${PROFILE_NAME}"
mkdir -p "$BUILD_DIR"

echo "Exporting artifacts without symlinks (direct files only)"

# Run pmbootstrap as a normal user (it refuses root). Optional: sudo -u when make was sudo.
pmb_exec() {
    local -a env_args=(env "PATH=$PATH")
    if [ -n "${PMB_WORK_OVERRIDE:-}" ]; then
        env_args+=("PMB_WORK_OVERRIDE=$PMB_WORK_OVERRIDE")
    fi
    if [ "$(id -u)" -eq 0 ]; then
        if [ -z "${SUDO_USER:-}" ]; then
            echo "ERROR: pmbootstrap must not run as root." >&2
            echo "  Run: make build   (as ubuntu), not: sudo make build" >&2
            exit 1
        fi
        local su_home
        su_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        env_args=(env "PATH=${su_home}/.local/bin:${PATH}")
        if [ -n "${PMB_WORK_OVERRIDE:-}" ]; then
            env_args+=("PMB_WORK_OVERRIDE=$PMB_WORK_OVERRIDE")
        fi
        sudo -u "$SUDO_USER" -H "${env_args[@]}" bash "$PMB" "$PROFILE_ENV" "$@"
    else
        "${env_args[@]}" bash "$PMB" "$PROFILE_ENV" "$@"
    fi
}

# Intentionally avoid 'pmbootstrap export' here because it creates symlinks.
# Host flashing paths should be real files, not links into pmbootstrap workdirs.

# rm(1)/mv(1)/rename(2) on some VM shared-folder mounts (virtiofs/9p) can
# return EOVERFLOW ("Value too large for defined data type") for multi-GB
# images. Avoid in-place replacement in pmbootstrap export dirs that already
# contain symlinks; write core images into a fresh side directory.
py_unlink() {
    python3 -c 'import os, sys
for p in sys.argv[1:]:
    try:
        os.unlink(p)
    except FileNotFoundError:
        pass
' "$@"
}

file_size() {
    python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]))' "$1" 2>/dev/null || echo 0
}

# Resolve pmbootstrap work dir on the host (same rules as scripts/pmb/pmb.sh).
pmb_work_abs() {
    local w="${PMB_WORK_OVERRIDE:-${PMB_WORK:-}}"
    if [ -z "$w" ]; then
        echo ""
        return 1
    fi
    if [[ "$w" = /* ]]; then
        echo "$w"
    else
        echo "$ROOT_DIR/$w"
    fi
}

# Copy multi-GB images with plain filesystem I/O. Prefer this over
# `pmbootstrap chroot --output stdout -- cat …`, which streams through Python
# and often hits [Errno 5] EIO on virtiofs / VM disks / large payloads.
copy_artifact_from_host() {
    local src="$1"
    local dst="$2"
    if [ -z "$src" ] || [ ! -f "$src" ] || [ ! -r "$src" ]; then
        return 1
    fi
    echo "Export: copying from host workdir: $src"
    py_unlink "$dst"
    if cp --sparse=always -- "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    if dd if="$src" of="$dst" bs=64M conv=sparse status=none 2>/dev/null; then
        return 0
    fi
    return 1
}

# Fallback: stream out of chroots (matches pmb.export.symlinks(): boot from device
# rootfs -r; disk image from native chroot). Retries help transient EIO.
#
# pmbootstrap 3.9+ uses RunOutputTypeDefault.from_string(): the CLI must pass
# lowercase "stdout". Uppercase "STDOUT" matches the enum *name* in --help but
# is rejected by the parser ("invalid from_string value: 'STDOUT'").
PMB_CHROOT_OUTPUT_MODE=stdout

stream_boot_from_chroot() {
    pmb_exec chroot --output "$PMB_CHROOT_OUTPUT_MODE" -r -- cat /boot/boot.img >"$BOOT_OUT"
}

stream_vendor_boot_from_chroot() {
    pmb_exec chroot --output "$PMB_CHROOT_OUTPUT_MODE" -r -- cat /boot/vendor_boot.img >"$BOOT_OUT"
}

stream_disk_from_chroot() {
    pmb_exec chroot --output "$PMB_CHROOT_OUTPUT_MODE" -- cat "/home/pmos/rootfs/${PROFILE_NAME}.img" >"$DISK_OUT"
}

# Treat undersized output as failure (EIO can still exit 0 from outer tools).
stream_boot_ok() {
    stream_boot_from_chroot || return 1
    local sz
    sz=$(file_size "$BOOT_OUT")
    [ "${sz:-0}" -ge 1048576 ]
}

stream_vendor_boot_ok() {
    stream_vendor_boot_from_chroot || return 1
    local sz
    sz=$(file_size "$BOOT_OUT")
    [ "${sz:-0}" -ge 1048576 ]
}

stream_disk_ok() {
    stream_disk_from_chroot || return 1
    local sz
    sz=$(file_size "$DISK_OUT")
    [ "${sz:-0}" -ge 10485760 ]
}

# Run a copy/stream function up to $1 times on failure (e.g. EIO).
retry_export_step() {
    local max_attempts="$1"
    shift
    local attempt=1
    local delay=2
    while [ "$attempt" -le "$max_attempts" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "WARNING: export step failed (attempt $attempt/$max_attempts), retrying in ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

CORE_EXPORT_DIR="${EXPORT_DIR}.core.$(date +%s)"
mkdir -p "$CORE_EXPORT_DIR"
echo "Copying boot.img and ${PROFILE_NAME}.img to: $CORE_EXPORT_DIR"

BOOT_OUT="$CORE_EXPORT_DIR/boot.img"
DISK_OUT="$CORE_EXPORT_DIR/${PROFILE_NAME}.img"
py_unlink "$BOOT_OUT" "$DISK_OUT"

PMB_W="$(pmb_work_abs || true)"
ROOTFS_CHROOT_NAME="${PMOS_DEVICE:-$PROFILE_NAME}"
HOST_BOOT=""
HOST_VENDOR_BOOT=""
HOST_DISK=""
if [ -n "$PMB_W" ] && [ -d "$PMB_W" ]; then
    HOST_BOOT="$PMB_W/chroot_rootfs_${ROOTFS_CHROOT_NAME}/boot/boot.img"
    HOST_VENDOR_BOOT="$PMB_W/chroot_rootfs_${ROOTFS_CHROOT_NAME}/boot/vendor_boot.img"
    HOST_DISK="$PMB_W/chroot_native/home/pmos/rootfs/${PROFILE_NAME}.img"
fi

boot_sz=0
if copy_artifact_from_host "$HOST_BOOT" "$BOOT_OUT"; then
    boot_sz=$(file_size "$BOOT_OUT")
fi
if [ "${boot_sz:-0}" -lt 1048576 ] && [ -n "$HOST_VENDOR_BOOT" ]; then
    py_unlink "$BOOT_OUT"
    if copy_artifact_from_host "$HOST_VENDOR_BOOT" "$BOOT_OUT"; then
        boot_sz=$(file_size "$BOOT_OUT")
    fi
fi
set +o pipefail
if [ "${boot_sz:-0}" -lt 1048576 ]; then
    py_unlink "$BOOT_OUT"
    retry_export_step 3 stream_boot_ok || true
    boot_sz=$(file_size "$BOOT_OUT")
fi
if [ "${boot_sz:-0}" -lt 1048576 ]; then
    py_unlink "$BOOT_OUT"
    retry_export_step 3 stream_vendor_boot_ok || true
    boot_sz=$(file_size "$BOOT_OUT")
fi
set -o pipefail

if [ "${boot_sz:-0}" -lt 1048576 ]; then
    echo "ERROR: boot image export failed (host paths tried + chroot stream for boot.img / vendor_boot.img)." >&2
    py_unlink "$BOOT_OUT"
    exit 1
fi

disk_sz=0
if copy_artifact_from_host "$HOST_DISK" "$DISK_OUT"; then
    disk_sz=$(file_size "$DISK_OUT")
fi
if [ "${disk_sz:-0}" -lt 10485760 ]; then
    py_unlink "$DISK_OUT"
    set +o pipefail
    retry_export_step 3 stream_disk_ok || true
    set -o pipefail
    disk_sz=$(file_size "$DISK_OUT")
fi
if [ "${disk_sz:-0}" -lt 10485760 ]; then
    echo "ERROR: rootfs disk image export failed: /home/pmos/rootfs/${PROFILE_NAME}.img ($disk_sz bytes)." >&2
    echo "  Hint: keep PMB_WORK on a local ext4 disk (not virtiofs); or retry after [Errno 5] EIO." >&2
    py_unlink "$DISK_OUT"
    exit 1
fi

FINAL_EXPORT_DIR="$CORE_EXPORT_DIR"

python3 - "$FINAL_EXPORT_DIR" "$PROFILE_NAME" <<'PY'
import pathlib
import struct
import sys

export_dir = pathlib.Path(sys.argv[1])
profile_name = sys.argv[2]
disk_img = export_dir / f"{profile_name}.img"
boot_out = export_dir / f"{profile_name}-boot.img"
root_out = export_dir / f"{profile_name}-root.img"

def path_exists(path: pathlib.Path) -> bool:
    try:
        return path.exists()
    except PermissionError:
        return False

if not path_exists(disk_img) or (path_exists(boot_out) and path_exists(root_out)):
    raise SystemExit(0)

SECTOR = 512

def read_gpt(path: pathlib.Path):
    with path.open("rb") as f:
        f.seek(SECTOR)
        hdr = f.read(92)
        if len(hdr) < 92 or hdr[:8] != b"EFI PART":
            return []
        part_entry_lba = struct.unpack_from("<Q", hdr, 72)[0]
        num_entries = struct.unpack_from("<I", hdr, 80)[0]
        entry_size = struct.unpack_from("<I", hdr, 84)[0]

        f.seek(part_entry_lba * SECTOR)
        entries_raw = f.read(num_entries * entry_size)

    entries = []
    for i in range(num_entries):
        off = i * entry_size
        entry = entries_raw[off : off + entry_size]
        first_lba = struct.unpack_from("<Q", entry, 32)[0]
        last_lba = struct.unpack_from("<Q", entry, 40)[0]
        if first_lba == 0 and last_lba == 0:
            continue
        name = entry[56:128].decode("utf-16le", errors="ignore").rstrip("\x00")
        entries.append((name.lower(), first_lba, last_lba))
    return entries

def extract_range(src: pathlib.Path, dst: pathlib.Path, first_lba: int, last_lba: int):
    start = first_lba * SECTOR
    end = (last_lba + 1) * SECTOR
    size = end - start
    with src.open("rb") as rf, dst.open("wb") as wf:
        rf.seek(start)
        remaining = size
        while remaining > 0:
            chunk = rf.read(min(4 * 1024 * 1024, remaining))
            if not chunk:
                break
            wf.write(chunk)
            remaining -= len(chunk)

try:
    entries = read_gpt(disk_img)
except PermissionError:
    print(f"WARNING: cannot read exported image (permission denied): {disk_img}", file=sys.stderr)
    raise SystemExit(0)
if not entries:
    raise SystemExit(0)

boot_entry = next((e for e in entries if "boot" in e[0]), None)
root_entry = next((e for e in entries if "root" in e[0] or "system" in e[0]), None)

if boot_entry and not path_exists(boot_out):
    try:
        extract_range(disk_img, boot_out, boot_entry[1], boot_entry[2])
    except PermissionError:
        print(f"WARNING: cannot write split boot image (permission denied): {boot_out}", file=sys.stderr)
if root_entry and not path_exists(root_out):
    try:
        extract_range(disk_img, root_out, root_entry[1], root_entry[2])
    except PermissionError:
        print(f"WARNING: cannot write split root image (permission denied): {root_out}", file=sys.stderr)
PY

python3 - "$FINAL_EXPORT_DIR" <<'PY'
import pathlib
import sys

export_dir = pathlib.Path(sys.argv[1])
manifest = export_dir / "ARTIFACTS.txt"
try:
    files = sorted(p.name for p in export_dir.iterdir() if p.is_file())
except PermissionError:
    print(f"WARNING: cannot list export artifacts (permission denied): {export_dir}", file=sys.stderr)
    raise SystemExit(0)
try:
    manifest.write_text(
        "Exported files:\n" + "\n".join(f"- {name}" for name in files) + ("\n" if files else ""),
        encoding="utf-8",
    )
except PermissionError:
    print(f"WARNING: cannot write artifact manifest (permission denied): {manifest}", file=sys.stderr)
PY

check_artifact_readable() {
    local artifact="$1"
    [ -e "$artifact" ] || return 1
    [ -r "$artifact" ] || return 1
    if [ -L "$artifact" ]; then
        local target
        target="$(readlink -f "$artifact" 2>/dev/null || true)"
        [ -n "$target" ] || return 1
        [ -r "$target" ] || return 1
    fi
    return 0
}

REQUIRED_BOOT="$FINAL_EXPORT_DIR/boot.img"
REQUIRED_DISK="$FINAL_EXPORT_DIR/${PROFILE_NAME}.img"
if ! check_artifact_readable "$REQUIRED_BOOT" || ! check_artifact_readable "$REQUIRED_DISK"; then
    echo "ERROR: exported core artifacts are missing or unreadable." >&2
    echo "  boot: $REQUIRED_BOOT" >&2
    echo "  disk: $REQUIRED_DISK" >&2
    exit 3
fi

# Always stage host-share-safe artifacts inside the repo (no symlinks).
HOST_BUNDLE_DIR="$ROOT_DIR/build/host-export-${PROFILE_NAME}"
python3 - "$FINAL_EXPORT_DIR" "$HOST_BUNDLE_DIR" "$PROFILE_NAME" <<'PY'
import os
import pathlib
import shutil
import sys

src_dir = pathlib.Path(sys.argv[1])
dst_dir = pathlib.Path(sys.argv[2])
profile = sys.argv[3]

core = [src_dir / "boot.img", src_dir / f"{profile}.img"]
optional = [
    src_dir / f"pmos-{profile}.zip",
    src_dir / f"{profile}-boot.img",
    src_dir / f"{profile}-root.img",
]

if dst_dir.exists():
    shutil.rmtree(dst_dir, ignore_errors=True)
dst_dir.mkdir(parents=True, exist_ok=True)

def copy_real_file(src: pathlib.Path, dst: pathlib.Path, required: bool = True):
    try:
        if not src.exists():
            if required:
                raise FileNotFoundError(f"missing required artifact: {src}")
            return
    except PermissionError as exc:
        if required:
            raise RuntimeError(f"cannot access required artifact {src}: {exc}") from exc
        return

    real_src = src.resolve(strict=False)
    try:
        with real_src.open("rb") as rf, dst.open("wb") as wf:
            shutil.copyfileobj(rf, wf)
    except Exception as exc:
        if required:
            raise RuntimeError(f"failed copying {src} -> {dst}: {exc}") from exc
        return
    os.chmod(dst, 0o644)

for f in core:
    copy_real_file(f, dst_dir / f.name, required=True)
for f in optional:
    copy_real_file(f, dst_dir / f.name, required=False)

for f in dst_dir.iterdir():
    if f.is_symlink():
        raise RuntimeError(f"host bundle contains symlink unexpectedly: {f}")
PY

mkdir -p "$ROOT_DIR/build" >/dev/null 2>&1 || true
printf '%s\n' "$HOST_BUNDLE_DIR" > "$ROOT_DIR/build/LAST_EXPORT_DIR_${PROFILE_NAME}.txt" || true

echo "Final export directory: $HOST_BUNDLE_DIR"
echo "Core artifacts:"
echo "  $HOST_BUNDLE_DIR/boot.img"
echo "  $HOST_BUNDLE_DIR/${PROFILE_NAME}.img"
echo "Export complete."
