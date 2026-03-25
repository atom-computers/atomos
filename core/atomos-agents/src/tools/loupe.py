"""Loupe image viewer adapter for atomos-agents.

Connects to Loupe (GNOME image viewer) running in iso-ubuntu.  Uses
D-Bus activation to open images and extracts metadata via CLI tools
(``exiftool``, ``identify``) or Python's ``PIL`` when available.

Tools: image_open, image_metadata
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_LOUPE_BUS = "org.gnome.Loupe"
_LOUPE_PATH = "/org/gnome/Loupe"


@register_app_adapter
class LoupeAdapter(AppAdapter):
    namespace = "image"
    app_id = "org.gnome.Loupe"
    binary = "loupe"

    def get_tools(self) -> list:
        return [image_open, image_metadata]


_adapter: LoupeAdapter | None = None


def _get_adapter() -> LoupeAdapter:
    global _adapter
    if _adapter is None:
        _adapter = LoupeAdapter()
    return _adapter


@tool
def image_open(file_path: str) -> str:
    """Open an image file in Loupe (GNOME image viewer).

    Accepts any common image format (PNG, JPEG, WEBP, SVG, etc.).
    The file must exist in the iso-ubuntu filesystem.
    """
    path = Path(file_path).expanduser().resolve()
    if not path.exists():
        return f"File not found: {file_path}"
    if not path.is_file():
        return f"Not a file: {file_path}"

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _LOUPE_BUS, _LOUPE_PATH,
            "org.freedesktop.Application", "Open",
            f"['file://{path}']", "{}",
        )
        return f"Opened in Loupe: {path}"
    except DBusError:
        try:
            subprocess.Popen(
                ["loupe", str(path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return f"Opened in Loupe (via CLI): {path}"
        except FileNotFoundError:
            try:
                subprocess.Popen(
                    ["xdg-open", str(path)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return f"Opened with default viewer: {path}"
            except FileNotFoundError:
                return f"Cannot open image — no viewer found"


@tool
def image_metadata(file_path: str) -> str:
    """Get metadata for an image file.

    Returns dimensions, format, file size, and EXIF data (camera model,
    date taken, GPS coordinates, etc.) when available.
    """
    path = Path(file_path).expanduser().resolve()
    if not path.exists():
        return f"File not found: {file_path}"

    info: dict = {
        "file": str(path),
        "size_bytes": path.stat().st_size,
    }

    # Try PIL/Pillow first
    try:
        from PIL import Image
        from PIL.ExifTags import TAGS

        with Image.open(path) as img:
            info["format"] = img.format or path.suffix.lstrip(".")
            info["width"] = img.width
            info["height"] = img.height
            info["mode"] = img.mode

            exif_data = img.getexif()
            if exif_data:
                exif_dict = {}
                for tag_id, value in exif_data.items():
                    tag_name = TAGS.get(tag_id, str(tag_id))
                    if isinstance(value, bytes):
                        continue
                    exif_dict[tag_name] = str(value)
                if exif_dict:
                    info["exif"] = exif_dict

        return json.dumps(info, indent=2)
    except ImportError:
        pass
    except Exception as exc:
        logger.debug("PIL metadata extraction failed: %s", exc)

    # Fallback: exiftool
    import shutil
    if shutil.which("exiftool"):
        try:
            proc = subprocess.run(
                ["exiftool", "-json", str(path)],
                capture_output=True, text=True, timeout=10,
            )
            if proc.returncode == 0 and proc.stdout:
                exif_list = json.loads(proc.stdout)
                if exif_list:
                    info.update(exif_list[0])
                return json.dumps(info, indent=2)
        except (subprocess.TimeoutExpired, json.JSONDecodeError):
            pass

    # Fallback: identify (ImageMagick)
    if shutil.which("identify"):
        try:
            proc = subprocess.run(
                ["identify", "-verbose", str(path)],
                capture_output=True, text=True, timeout=10,
            )
            if proc.returncode == 0:
                info["identify_output"] = proc.stdout[:2000]
                return json.dumps(info, indent=2)
        except subprocess.TimeoutExpired:
            pass

    # Fallback: file command
    try:
        proc = subprocess.run(
            ["file", "--mime-type", "-b", str(path)],
            capture_output=True, text=True, timeout=5,
        )
        if proc.returncode == 0:
            info["mime_type"] = proc.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return json.dumps(info, indent=2)


# ── registration helper ───────────────────────────────────────────────────

_LOUPE_TOOLS = None


def get_loupe_tools() -> list:
    """Return all Loupe image tools. Returns ``[]`` if not installed."""
    global _LOUPE_TOOLS
    if _LOUPE_TOOLS is not None:
        return _LOUPE_TOOLS

    import shutil
    if shutil.which("loupe") is not None:
        _LOUPE_TOOLS = [image_open, image_metadata]
    else:
        logger.warning("Loupe not installed — image tools unavailable")
        _LOUPE_TOOLS = []

    return _LOUPE_TOOLS
