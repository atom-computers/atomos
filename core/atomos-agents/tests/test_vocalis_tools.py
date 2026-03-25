"""
Tests for the Vocalis voice recorder adapter (tools/vocalis.py).

Covers:
  - Tool registration and discovery via get_vocalis_tools()
  - Tool names and argument schemas
  - D-Bus and GStreamer fallback recording
  - Recording state management (start/stop)
  - Error handling
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch, PropertyMock
from pathlib import Path

from tools.app_adapter import DBusError


def _reset():
    import tools.vocalis as mod
    mod._adapter = None
    mod._VOCALIS_TOOLS = None
    mod._recording_process = None
    mod._recording_path = None


class TestVocalisToolRegistration:

    def test_get_vocalis_tools_returns_three(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/vocalis"):
            from tools.vocalis import get_vocalis_tools
            result = get_vocalis_tools()
            assert len(result) == 3
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/vocalis"):
            from tools.vocalis import get_vocalis_tools
            names = {t.name for t in get_vocalis_tools()}
            assert names == {"voice_record_start", "voice_record_stop", "voice_recordings_list"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.vocalis import get_vocalis_tools
            result = get_vocalis_tools()
            assert result == []
        _reset()

    def test_returns_tools_when_gstreamer_available(self):
        _reset()
        def fake_which(name):
            if name == "gst-launch-1.0":
                return "/usr/bin/gst-launch-1.0"
            return None
        with patch("shutil.which", side_effect=fake_which):
            from tools.vocalis import get_vocalis_tools
            result = get_vocalis_tools()
            assert len(result) == 3
        _reset()


class TestVoiceRecordStart:

    def test_start_via_dbus(self):
        _reset()
        from tools.vocalis import voice_record_start, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.vocalis._find_recordings_dir", return_value=Path("/tmp/recordings")):
            result = voice_record_start.invoke({})
            assert "Recording started" in result
        _reset()

    def test_start_with_custom_filename(self):
        _reset()
        from tools.vocalis import voice_record_start, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.vocalis._find_recordings_dir", return_value=Path("/tmp/recordings")):
            result = voice_record_start.invoke({"filename": "meeting.ogg"})
            assert "Recording started" in result
            assert "meeting.ogg" in result
        _reset()

    def test_start_gstreamer_fallback(self):
        _reset()
        from tools.vocalis import voice_record_start, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no vocalis")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.vocalis._find_recordings_dir", return_value=Path("/tmp/recordings")), \
             patch("shutil.which", return_value="/usr/bin/gst-launch-1.0"), \
             patch("subprocess.Popen") as mock_popen:
            mock_popen.return_value = MagicMock()
            result = voice_record_start.invoke({})
            assert "Recording started" in result
            assert "GStreamer" in result
        _reset()

    def test_start_when_already_recording(self):
        _reset()
        import tools.vocalis as mod
        mod._recording_process = MagicMock()

        from tools.vocalis import voice_record_start
        result = voice_record_start.invoke({})
        assert "already in progress" in result
        _reset()

    def test_start_no_recorder_available(self):
        _reset()
        from tools.vocalis import voice_record_start, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no vocalis")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.vocalis._find_recordings_dir", return_value=Path("/tmp/recordings")), \
             patch("shutil.which", return_value=None):
            result = voice_record_start.invoke({})
            assert "unavailable" in result.lower()
        _reset()


class TestVoiceRecordStop:

    def test_stop_via_dbus(self):
        _reset()
        from tools.vocalis import voice_record_stop, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = voice_record_stop.invoke({})
            assert "stopped" in result.lower() or "Recording" in result
        _reset()

    def test_stop_gstreamer_process(self):
        _reset()
        import tools.vocalis as mod
        fake_proc = MagicMock()
        fake_proc.terminate = MagicMock()
        fake_proc.wait = MagicMock()
        mod._recording_process = fake_proc
        mod._recording_path = Path("/tmp/recordings/test.ogg")

        from tools.vocalis import voice_record_stop, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no vocalis")
        adapter._dbus = mock_dbus

        result = voice_record_stop.invoke({})
        fake_proc.terminate.assert_called_once()
        assert "stopped" in result.lower() or "Recording" in result
        _reset()

    def test_stop_no_recording_in_progress(self):
        _reset()
        from tools.vocalis import voice_record_stop, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("nothing to stop")
        adapter._dbus = mock_dbus

        result = voice_record_stop.invoke({})
        assert "No recording" in result
        _reset()


class TestVoiceRecordingsList:

    def test_list_recordings(self, tmp_path):
        _reset()
        rec_file = tmp_path / "recording_20250101.ogg"
        rec_file.write_bytes(b"\x00" * 1024)

        from tools.vocalis import voice_recordings_list
        with patch("tools.vocalis._find_recordings_dir", return_value=tmp_path):
            result = voice_recordings_list.invoke({"limit": 20})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["filename"] == "recording_20250101.ogg"
            assert parsed[0]["size_bytes"] == 1024
        _reset()

    def test_list_empty_directory(self, tmp_path):
        _reset()
        from tools.vocalis import voice_recordings_list
        with patch("tools.vocalis._find_recordings_dir", return_value=tmp_path):
            result = voice_recordings_list.invoke({"limit": 20})
            assert "no recordings found" in result
        _reset()

    def test_list_filters_non_audio(self, tmp_path):
        _reset()
        (tmp_path / "notes.txt").write_text("not audio")
        (tmp_path / "song.mp3").write_bytes(b"\x00" * 512)

        from tools.vocalis import voice_recordings_list
        with patch("tools.vocalis._find_recordings_dir", return_value=tmp_path):
            result = voice_recordings_list.invoke({"limit": 20})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["filename"] == "song.mp3"
        _reset()


class TestRegistryIntegration:

    def test_vocalis_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "voice_record_start" in _ALLOWED_EXPOSED_TOOLS
        assert "voice_record_stop" in _ALLOWED_EXPOSED_TOOLS
        assert "voice_recordings_list" in _ALLOWED_EXPOSED_TOOLS
