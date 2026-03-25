"""Vocalis voice recorder adapter for atomos-agents.

Connects to Vocalis running in iso-ubuntu via D-Bus or CLI for recording
control.  Recordings are stored as audio files in the user's home directory.

Tools: voice_record_start, voice_record_stop, voice_recordings_list
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from datetime import datetime
from pathlib import Path

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_VOCALIS_BUS = "org.gnome.Vocalis"
_VOCALIS_PATH = "/org/gnome/Vocalis"
_VOCALIS_IFACE = "org.gnome.Vocalis"

_RECORDINGS_DIRS = [
    Path.home() / "Recordings",
    Path.home() / ".local" / "share" / "vocalis",
    Path.home() / "Music" / "Recordings",
]


def _find_recordings_dir() -> Path:
    """Locate or create the recordings directory."""
    for d in _RECORDINGS_DIRS:
        if d.exists():
            return d
    default = _RECORDINGS_DIRS[0]
    default.mkdir(parents=True, exist_ok=True)
    return default


@register_app_adapter
class VocalisAdapter(AppAdapter):
    namespace = "voice"
    app_id = "org.gnome.Vocalis"
    binary = "vocalis"

    def get_tools(self) -> list:
        return [voice_record_start, voice_record_stop, voice_recordings_list]


_adapter: VocalisAdapter | None = None
_recording_process: subprocess.Popen | None = None
_recording_path: Path | None = None


def _get_adapter() -> VocalisAdapter:
    global _adapter
    if _adapter is None:
        _adapter = VocalisAdapter()
    return _adapter


def _check_running() -> str | None:
    return _get_adapter().ensure_running()


@tool
def voice_record_start(filename: str = "") -> str:
    """Start a voice recording.

    If filename is provided, the recording will be saved with that name.
    Otherwise a timestamped filename is generated.  Uses Vocalis if
    available, falls back to GStreamer CLI.
    """
    global _recording_process, _recording_path

    if _recording_process is not None:
        return "Recording already in progress. Stop it first with voice_record_stop."

    rec_dir = _find_recordings_dir()
    if not filename:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"recording_{ts}.ogg"
    _recording_path = rec_dir / filename

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _VOCALIS_BUS, _VOCALIS_PATH,
            _VOCALIS_IFACE, "StartRecording",
            f"'{_recording_path}'",
        )
        return f"Recording started: {_recording_path}"
    except (DBusError, Exception):
        pass

    import shutil
    if shutil.which("gst-launch-1.0"):
        try:
            _recording_process = subprocess.Popen(
                [
                    "gst-launch-1.0", "-e",
                    "pulsesrc", "!",
                    "audioconvert", "!",
                    "vorbisenc", "!",
                    "oggmux", "!",
                    "filesink", f"location={_recording_path}",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return f"Recording started (GStreamer fallback): {_recording_path}"
        except Exception as exc:
            _recording_process = None
            return f"Failed to start recording: {exc}"

    return "Recording unavailable — neither Vocalis nor GStreamer found"


@tool
def voice_record_stop() -> str:
    """Stop the current voice recording.

    Returns the path and file size of the saved recording.
    """
    global _recording_process, _recording_path

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _VOCALIS_BUS, _VOCALIS_PATH,
            _VOCALIS_IFACE, "StopRecording",
        )
        path = _recording_path
        _recording_path = None
        if path and path.exists():
            size = path.stat().st_size
            return f"Recording saved: {path} ({size} bytes)"
        return "Recording stopped"
    except (DBusError, Exception):
        pass

    if _recording_process is not None:
        _recording_process.terminate()
        try:
            _recording_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _recording_process.kill()
        _recording_process = None

        path = _recording_path
        _recording_path = None
        if path and path.exists():
            size = path.stat().st_size
            return f"Recording saved: {path} ({size} bytes)"
        return "Recording stopped (file may still be finalizing)"

    return "No recording in progress"


@tool
def voice_recordings_list(limit: int = 20) -> str:
    """List saved voice recordings.

    Returns filename, size, and creation date for each recording.
    """
    rec_dir = _find_recordings_dir()
    audio_exts = {".ogg", ".wav", ".mp3", ".flac", ".m4a", ".opus"}
    files = []
    try:
        for f in sorted(rec_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            if f.suffix.lower() in audio_exts and f.is_file():
                stat = f.stat()
                files.append({
                    "filename": f.name,
                    "path": str(f),
                    "size_bytes": stat.st_size,
                    "created": datetime.fromtimestamp(stat.st_ctime).isoformat(),
                })
                if len(files) >= limit:
                    break
    except OSError:
        pass

    if not files:
        return "(no recordings found)"
    return json.dumps(files, indent=2)


# ── registration helper ───────────────────────────────────────────────────

_VOCALIS_TOOLS = None


def get_vocalis_tools() -> list:
    """Return all Vocalis tools. Returns ``[]`` if not installed."""
    global _VOCALIS_TOOLS
    if _VOCALIS_TOOLS is not None:
        return _VOCALIS_TOOLS

    import shutil
    has_vocalis = shutil.which("vocalis") is not None
    has_gstreamer = shutil.which("gst-launch-1.0") is not None
    if has_vocalis or has_gstreamer:
        _VOCALIS_TOOLS = [voice_record_start, voice_record_stop, voice_recordings_list]
    else:
        logger.warning("Vocalis/GStreamer not installed — voice recording tools unavailable")
        _VOCALIS_TOOLS = []

    return _VOCALIS_TOOLS
