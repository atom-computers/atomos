"""Amberol music player adapter for atomos-agents.

Connects to Amberol running in iso-ubuntu via the standard MPRIS2 D-Bus
interface (``org.mpris.MediaPlayer2``).  This is the same interface used
by all modern Linux media players, making the adapter reusable.

Tools: music_play, music_pause, music_skip, music_queue, music_now_playing
"""

from __future__ import annotations

import json
import logging
import re

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_MPRIS_BUS = "org.mpris.MediaPlayer2.Amberol"
_MPRIS_PATH = "/org/mpris/MediaPlayer2"
_MPRIS_PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
_MPRIS_IFACE = "org.mpris.MediaPlayer2"


@register_app_adapter
class AmberolAdapter(AppAdapter):
    namespace = "music"
    app_id = "io.bassi.Amberol"
    binary = "amberol"

    def get_tools(self) -> list:
        return [music_play, music_pause, music_skip, music_queue, music_now_playing]


_adapter: AmberolAdapter | None = None


def _get_adapter() -> AmberolAdapter:
    global _adapter
    if _adapter is None:
        _adapter = AmberolAdapter()
    return _adapter


def _check_running() -> str | None:
    return _get_adapter().ensure_running()


def _parse_variant(raw: str) -> str:
    """Strip GVariant wrapper from gdbus output for readability."""
    stripped = raw.strip()
    if stripped.startswith("(") and stripped.endswith(")"):
        stripped = stripped[1:-1].strip()
    if stripped.startswith("'") and stripped.endswith("'"):
        stripped = stripped[1:-1]
    return stripped


def _get_metadata() -> dict:
    """Read the current track metadata from MPRIS2."""
    adapter = _get_adapter()
    try:
        raw = adapter.dbus.get_property(
            _MPRIS_BUS, _MPRIS_PATH,
            _MPRIS_PLAYER_IFACE, "Metadata",
        )
        title = ""
        artist = ""
        album = ""
        length_us = 0

        if "xesam:title" in raw:
            m = re.search(r"xesam:title.*?<'([^']+)'>", raw)
            if m:
                title = m.group(1)
        if "xesam:artist" in raw:
            m = re.search(r"xesam:artist.*?<'([^']+)'>", raw)
            if not m:
                m = re.search(r"xesam:artist.*?\['([^']+)'\]", raw)
            if m:
                artist = m.group(1)
        if "xesam:album" in raw:
            m = re.search(r"xesam:album.*?<'([^']+)'>", raw)
            if m:
                album = m.group(1)
        if "mpris:length" in raw:
            m = re.search(r"mpris:length.*?(\d+)", raw)
            if m:
                length_us = int(m.group(1))

        return {
            "title": title or "(unknown)",
            "artist": artist or "(unknown)",
            "album": album or "(unknown)",
            "duration_seconds": length_us // 1_000_000 if length_us else 0,
        }
    except DBusError:
        return {}


@tool
def music_play(uri: str = "") -> str:
    """Start playback in Amberol.

    If a URI is provided (file path or URL), opens that track.
    Otherwise resumes the current track.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        if uri:
            adapter.dbus.call(
                _MPRIS_BUS, _MPRIS_PATH,
                _MPRIS_PLAYER_IFACE, "OpenUri",
                f"'{uri}'",
            )
            return f"Playing: {uri}"
        else:
            adapter.dbus.call(
                _MPRIS_BUS, _MPRIS_PATH,
                _MPRIS_PLAYER_IFACE, "Play",
            )
            meta = _get_metadata()
            if meta:
                return f"Resumed: {meta.get('title', '?')} — {meta.get('artist', '?')}"
            return "Playback resumed"
    except DBusError as exc:
        return f"Failed to play: {exc}"


@tool
def music_pause() -> str:
    """Pause playback in Amberol."""
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _MPRIS_BUS, _MPRIS_PATH,
            _MPRIS_PLAYER_IFACE, "Pause",
        )
        return "Playback paused"
    except DBusError as exc:
        return f"Failed to pause: {exc}"


@tool
def music_skip(direction: str = "next") -> str:
    """Skip to the next or previous track in Amberol.

    direction: 'next' or 'previous'
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    method = "Next" if direction == "next" else "Previous"
    try:
        adapter.dbus.call(
            _MPRIS_BUS, _MPRIS_PATH,
            _MPRIS_PLAYER_IFACE, method,
        )
        meta = _get_metadata()
        if meta:
            return f"Skipped {direction}: now playing {meta.get('title', '?')} — {meta.get('artist', '?')}"
        return f"Skipped {direction}"
    except DBusError as exc:
        return f"Failed to skip: {exc}"


@tool
def music_queue(uri: str) -> str:
    """Add a track to the Amberol play queue.

    uri: path to an audio file or a music URI
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _MPRIS_BUS, _MPRIS_PATH,
            _MPRIS_PLAYER_IFACE, "OpenUri",
            f"'{uri}'",
        )
        return f"Queued: {uri}"
    except DBusError as exc:
        return f"Failed to queue: {exc}"


@tool
def music_now_playing() -> str:
    """Get the currently playing track info from Amberol.

    Returns title, artist, album, and duration.
    """
    err = _check_running()
    if err:
        return err

    meta = _get_metadata()
    if not meta:
        return "(nothing playing or Amberol MPRIS2 interface not responding)"

    parts = [
        f"Title: {meta['title']}",
        f"Artist: {meta['artist']}",
        f"Album: {meta['album']}",
    ]
    if meta["duration_seconds"]:
        mins, secs = divmod(meta["duration_seconds"], 60)
        parts.append(f"Duration: {mins}:{secs:02d}")

    adapter = _get_adapter()
    try:
        status_raw = adapter.dbus.get_property(
            _MPRIS_BUS, _MPRIS_PATH,
            _MPRIS_PLAYER_IFACE, "PlaybackStatus",
        )
        status = _parse_variant(status_raw)
        parts.append(f"Status: {status}")
    except DBusError:
        pass

    return "\n".join(parts)


# ── registration helper ───────────────────────────────────────────────────

_AMBEROL_TOOLS = None


def get_amberol_tools() -> list:
    """Return all Amberol music tools. Returns ``[]`` if not installed."""
    global _AMBEROL_TOOLS
    if _AMBEROL_TOOLS is not None:
        return _AMBEROL_TOOLS

    import shutil
    if shutil.which("amberol") is not None:
        _AMBEROL_TOOLS = [music_play, music_pause, music_skip, music_queue, music_now_playing]
    else:
        logger.warning("Amberol not installed — music tools unavailable")
        _AMBEROL_TOOLS = []

    return _AMBEROL_TOOLS
