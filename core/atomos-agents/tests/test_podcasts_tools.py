"""
Tests for the GNOME Podcasts adapter (tools/podcasts.py).

Covers:
  - Tool registration and discovery via get_podcasts_tools()
  - Tool names and argument schemas
  - Handler invocation round-trip (mock D-Bus, mock SQLite)
  - Error handling when Podcasts is unavailable
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.podcasts as mod
    mod._adapter = None
    mod._PODCASTS_TOOLS = None


class TestPodcastsToolRegistration:

    def test_get_podcasts_tools_returns_four(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/gnome-podcasts"):
            from tools.podcasts import get_podcasts_tools
            result = get_podcasts_tools()
            assert len(result) == 4
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/gnome-podcasts"):
            from tools.podcasts import get_podcasts_tools
            names = {t.name for t in get_podcasts_tools()}
            assert names == {"podcast_subscribe", "podcast_list", "podcast_play", "podcast_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None), \
             patch("tools.podcasts._find_db", return_value=None):
            from tools.podcasts import get_podcasts_tools
            result = get_podcasts_tools()
            assert result == []
        _reset()

    def test_returns_tools_when_db_exists_but_binary_missing(self):
        _reset()
        from pathlib import Path
        with patch("shutil.which", return_value=None), \
             patch("tools.podcasts._find_db", return_value=Path("/fake/podcasts.db")):
            from tools.podcasts import get_podcasts_tools
            result = get_podcasts_tools()
            assert len(result) == 4
        _reset()


class TestPodcastSubscribe:

    def test_subscribe_via_dbus(self):
        _reset()
        from tools.podcasts import podcast_subscribe, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = podcast_subscribe.invoke({"feed_url": "https://example.com/feed.xml"})
            assert "Subscribed" in result
            assert "https://example.com/feed.xml" in result
        _reset()

    def test_subscribe_cli_fallback(self):
        _reset()
        from tools.podcasts import podcast_subscribe, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no bus")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.Popen") as mock_popen:
            result = podcast_subscribe.invoke({"feed_url": "https://example.com/feed.xml"})
            assert "Subscribed" in result
            assert "CLI" in result
        _reset()

    def test_subscribe_all_fallbacks_fail(self):
        _reset()
        from tools.podcasts import podcast_subscribe, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no bus")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.Popen", side_effect=FileNotFoundError("nope")):
            result = podcast_subscribe.invoke({"feed_url": "https://example.com/feed.xml"})
            assert "Failed" in result
        _reset()

    def test_subscribe_not_running(self):
        _reset()
        from tools.podcasts import podcast_subscribe, _get_adapter
        adapter = _get_adapter()

        with patch.object(adapter._lifecycle, "ensure_running", return_value="gnome-podcasts is not installed. Install it first."):
            result = podcast_subscribe.invoke({"feed_url": "https://example.com/feed.xml"})
            assert "not installed" in result
        _reset()


class TestPodcastList:

    def test_list_from_db(self):
        _reset()
        from tools.podcasts import podcast_list
        fake_rows = [
            {"title": "My Podcast", "description": "A show", "link": "https://example.com"},
        ]
        with patch("tools.podcasts._query_db", return_value=fake_rows):
            result = podcast_list.invoke({"limit": 20})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["title"] == "My Podcast"
        _reset()

    def test_list_dbus_fallback_when_no_db(self):
        _reset()
        from tools.podcasts import podcast_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Show A', 'Show B')"
        adapter._dbus = mock_dbus

        with patch("tools.podcasts._query_db", return_value=[]):
            result = podcast_list.invoke({"limit": 20})
            assert "Show A" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.podcasts import podcast_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch("tools.podcasts._query_db", return_value=[]):
            result = podcast_list.invoke({"limit": 20})
            assert "no subscribed podcasts" in result
        _reset()

    def test_list_dbus_error_and_no_db(self):
        _reset()
        from tools.podcasts import podcast_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("fail")
        adapter._dbus = mock_dbus

        with patch("tools.podcasts._query_db", return_value=[]):
            result = podcast_list.invoke({"limit": 20})
            assert "no subscribed podcasts" in result
            assert "database not found" in result
        _reset()


class TestPodcastPlay:

    def test_play_by_episode_id(self):
        _reset()
        from tools.podcasts import podcast_play, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = podcast_play.invoke({"episode_id": "ep-42"})
            assert "Playing episode" in result
            assert "ep-42" in result
        _reset()

    def test_play_by_show_title_db_lookup(self):
        _reset()
        from tools.podcasts import podcast_play, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        fake_rows = [{"id": 10, "title": "Episode 1", "uri": "https://example.com/ep1.mp3"}]
        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.podcasts._query_db", return_value=fake_rows):
            result = podcast_play.invoke({"show_title": "My Podcast"})
            assert "Playing" in result
            assert "Episode 1" in result
        _reset()

    def test_play_dbus_error(self):
        _reset()
        from tools.podcasts import podcast_play, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("play failed")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = podcast_play.invoke({"episode_id": "ep-99"})
            assert "Failed" in result
        _reset()


class TestPodcastSearch:

    def test_search_returns_results(self):
        _reset()
        from tools.podcasts import podcast_search
        fake_rows = [
            {"title": "AI News", "description": "Latest AI...", "show_title": "TechPod", "epoch": 1700000000},
        ]
        with patch("tools.podcasts._query_db", return_value=fake_rows):
            result = podcast_search.invoke({"query": "AI"})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["title"] == "AI News"
        _reset()

    def test_search_no_results(self):
        _reset()
        from tools.podcasts import podcast_search
        with patch("tools.podcasts._query_db", return_value=[]):
            result = podcast_search.invoke({"query": "nonexistent"})
            assert "no episodes matching" in result
        _reset()


class TestRegistryIntegration:

    def test_podcast_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "podcast_subscribe" in _ALLOWED_EXPOSED_TOOLS
        assert "podcast_list" in _ALLOWED_EXPOSED_TOOLS
        assert "podcast_play" in _ALLOWED_EXPOSED_TOOLS
        assert "podcast_search" in _ALLOWED_EXPOSED_TOOLS
