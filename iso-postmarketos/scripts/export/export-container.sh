#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <build-dir>" >&2
    exit 1
fi

PROFILE_ENV="$1"
BUILD_DIR="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "$PROFILE_ENV"

EXPORT_DIR="$BUILD_DIR/export-${PROFILE_NAME}"
if [ -e "$EXPORT_DIR" ]; then
    STALE_DIR="${EXPORT_DIR}.stale.$(date +%s)"
    mv "$EXPORT_DIR" "$STALE_DIR" || true
fi
mkdir -p "$EXPORT_DIR"

if [[ "$BUILD_DIR" == "$ROOT_DIR/"* ]]; then
    BUILD_DIR_REL="${BUILD_DIR#"$ROOT_DIR"/}"
elif [[ "$BUILD_DIR" == /* ]]; then
    echo "build-dir must be inside repo root when using container export: $BUILD_DIR" >&2
    exit 1
else
    BUILD_DIR_REL="$BUILD_DIR"
fi
EXPORT_DIR_REL="$BUILD_DIR_REL/export-${PROFILE_NAME}"

# pmb-container executes inside /work, so pass profile path relative to repo root.
if [[ "$PROFILE_ENV" == "$ROOT_DIR/"* ]]; then
    PROFILE_ENV_REL="${PROFILE_ENV#"$ROOT_DIR"/}"
else
    PROFILE_ENV_REL="$PROFILE_ENV"
fi

echo "Exporting artifacts (container) to: $EXPORT_DIR"
PMB_CONTAINER_AS_ROOT=1 bash "$ROOT_DIR/scripts/pmb/pmb-container.sh" "$PROFILE_ENV_REL" export "$EXPORT_DIR_REL"

# pmbootstrap may leave root-owned links/files in export dir.
# Normalize ownership so post-processing can rewrite symlinks safely.
if command -v sudo >/dev/null 2>&1; then
    sudo chown -hR "$(id -u):$(id -g)" "$EXPORT_DIR" >/dev/null 2>&1 || true
fi

# pmbootstrap export writes symlinks that target /work/... paths from inside the
# container. Replace those symlinks with real files/directories on the host.
python3 - "$EXPORT_DIR" "$ROOT_DIR" <<'PY'
import os
import pathlib
import shutil
import sys

export_dir = pathlib.Path(sys.argv[1])
root_dir = pathlib.Path(sys.argv[2])
missing = set()

for path in sorted(export_dir.rglob("*")):
    if not path.is_symlink():
        continue
    target = os.readlink(path)
    if os.path.isabs(target):
        if target.startswith("/work/"):
            host_src = root_dir / target[len("/work/") :]
        else:
            # Unknown absolute path from container; skip.
            continue
    else:
        host_src = (path.parent / target).resolve()

    if not host_src.exists():
        missing.add((path.name, target))
        continue

    path.unlink()
    if host_src.is_dir():
        shutil.copytree(host_src, path)
    else:
        shutil.copy2(host_src, path)

for path in sorted(export_dir.rglob("*")):
    if path.is_symlink():
        missing.add((path.name, os.readlink(path)))
        path.unlink()

if missing:
    lines = ["Some export artifacts were unavailable in this build context:"]
    lines.extend(f"- {name} (missing source: {target})" for name, target in missing)
    (export_dir / "MISSING_ARTIFACTS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

python3 - "$EXPORT_DIR" "$PROFILE_NAME" <<'PY'
import pathlib
import struct
import sys

export_dir = pathlib.Path(sys.argv[1])
profile_name = sys.argv[2]
disk_img = export_dir / f"{profile_name}.img"
boot_out = export_dir / f"{profile_name}-boot.img"
root_out = export_dir / f"{profile_name}-root.img"

if not disk_img.exists() or (boot_out.exists() and root_out.exists()):
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

entries = read_gpt(disk_img)
if not entries:
    raise SystemExit(0)

boot_entry = next((e for e in entries if "boot" in e[0]), None)
root_entry = next((e for e in entries if "root" in e[0] or "system" in e[0]), None)

if boot_entry and not boot_out.exists():
    extract_range(disk_img, boot_out, boot_entry[1], boot_entry[2])
if root_entry and not root_out.exists():
    extract_range(disk_img, root_out, root_entry[1], root_entry[2])
PY

python3 - "$EXPORT_DIR" <<'PY'
import pathlib
import sys

export_dir = pathlib.Path(sys.argv[1])
manifest = export_dir / "ARTIFACTS.txt"
files = sorted(p.name for p in export_dir.iterdir() if p.is_file())
manifest.write_text(
    "Exported files:\n" + "\n".join(f"- {name}" for name in files) + ("\n" if files else ""),
    encoding="utf-8",
)
PY

echo "Container export complete: $EXPORT_DIR"
