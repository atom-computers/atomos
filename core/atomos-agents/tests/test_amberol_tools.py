"""
Tests for the Amberol music adapter (tools/amberol.py).

Covers:
  - Tool registration and discovery
  - MPRIS2 D-Bus integration (mock)
  - Playback control, now-playing metadata
  - Registry integration
"""

import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.amberol as mod
    mod._adapter = None
    mod._AMBEROL_TOOLS = None


class TestAmberolToolRegistration:

    def test_get_amberol_tools_returns_five(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/amberol"):
            from tools.amberol import get_amberol_tools
            result = get_amberol_tools()
            assert len(result) == 5
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/amberol"):
            from tools.amberol import get_amberol_tools
            names = {t.name for t in get_amberol_tools()}
            assert names == {"music_play", "music_pause", "music_skip", "music_queue", "music_now_playing"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.amberol import get_amberol_tools
            assert get_amberol_tools() == []
        _reset()


class TestMusicPlay:

    def test_play_resume(self):
        _reset()
        from tools.amberol import music_play, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus
        mock_dbus.get_property.return_value = "(<{'xesam:title': <'Test Song'>}>,)"

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_play.invoke({})
            assert "resumed" in result.lower() or "Playing" in result or "Resumed" in result
        _reset()

    def test_play_with_uri(self):
        _reset()
        from tools.amberol import music_play, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_play.invoke({"uri": "/home/user/music/song.mp3"})
            assert "Playing" in result
        _reset()


class TestMusicPause:

    def test_pause(self):
        _reset()
        from tools.amberol import music_pause, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_pause.invoke({})
            assert "paused" in result.lower()
        _reset()

    def test_pause_dbus_error(self):
        _reset()
        from tools.amberol import music_pause, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("not running")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_pause.invoke({})
            assert "Failed" in result
        _reset()


class TestMusicSkip:

    def test_skip_next(self):
        _reset()
        from tools.amberol import music_skip, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus
        mock_dbus.get_property.return_value = ""

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_skip.invoke({"direction": "next"})
            assert "next" in result.lower() or "Skipped" in result
        _reset()

    def test_skip_previous(self):
        _reset()
        from tools.amberol import music_skip, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus
        mock_dbus.get_property.return_value = ""

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_skip.invoke({"direction": "previous"})
            assert "previous" in result.lower() or "Skipped" in result
        _reset()


class TestMusicNowPlaying:

    def test_now_playing_with_metadata(self):
        _reset()
        from tools.amberol import music_now_playing, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        metadata_str = (
            "(<{'xesam:title': <'Test Song'>, "
            "'xesam:artist': <'Test Artist'>, "
            "'xesam:album': <'Test Album'>, "
            "'mpris:length': <int64 240000000>}>,)"
        )
        mock_dbus.get_property.side_effect = [
            metadata_str,
            "(<'Playing'>,)",
        ]

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_now_playing.invoke({})
            assert "Test Song" in result
            assert "Test Artist" in result
            assert "Test Album" in result
        _reset()

    def test_now_playing_nothing(self):
        _reset()
        from tools.amberol import music_now_playing, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.get_property.side_effect = DBusError("no player")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = music_now_playing.invoke({})
            assert "nothing playing" in result.lower() or "not responding" in result
        _reset()


class TestRegistryIntegration:

    def test_amberol_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "music_play" in _ALLOWED_EXPOSED_TOOLS
        assert "music_pause" in _ALLOWED_EXPOSED_TOOLS
        assert "music_skip" in _ALLOWED_EXPOSED_TOOLS
        assert "music_queue" in _ALLOWED_EXPOSED_TOOLS
        assert "music_now_playing" in _ALLOWED_EXPOSED_TOOLS
