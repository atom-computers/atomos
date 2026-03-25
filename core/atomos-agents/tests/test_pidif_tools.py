"""
Tests for the Pidif feed reader adapter (tools/pidif.py).

Covers:
  - Tool registration and discovery via get_pidif_tools()
  - Tool names and argument schemas
  - CLI subprocess integration (mock)
  - Error handling (pidif not found, timeouts)
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.pidif as mod
    mod._adapter = None
    mod._PIDIF_TOOLS = None


class TestPidifToolRegistration:

    def test_get_pidif_tools_returns_five(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/pidif"):
            from tools.pidif import get_pidif_tools
            result = get_pidif_tools()
            assert len(result) == 5
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/pidif"):
            from tools.pidif import get_pidif_tools
            names = {t.name for t in get_pidif_tools()}
            assert names == {"feeds_add", "feeds_list", "feeds_articles", "feeds_read", "feeds_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.pidif import get_pidif_tools
            result = get_pidif_tools()
            assert result == []
        _reset()


class TestFeedsAdd:

    def test_add_feed_success(self):
        _reset()
        from tools.pidif import feeds_add
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Feed added successfully"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_add.invoke({"feed_url": "https://example.com/rss"})
            assert "Feed added" in result
            assert "https://example.com/rss" in result
        _reset()

    def test_add_feed_with_title(self):
        _reset()
        from tools.pidif import feeds_add
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Feed added"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_add.invoke({"feed_url": "https://example.com/rss", "title": "Tech News"})
            assert "Feed added" in result
            assert "Tech News" in result
        _reset()

    def test_add_feed_not_found(self):
        _reset()
        from tools.pidif import feeds_add
        with patch("tools.pidif.subprocess.run", side_effect=FileNotFoundError("pidif not found")):
            result = feeds_add.invoke({"feed_url": "https://example.com/rss"})
            assert "Failed" in result or "not found" in result
        _reset()

    def test_add_feed_error(self):
        _reset()
        from tools.pidif import feeds_add
        mock_proc = MagicMock()
        mock_proc.returncode = 1
        mock_proc.stdout = ""
        mock_proc.stderr = "error: invalid feed URL"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_add.invoke({"feed_url": "not-a-url"})
            assert "Failed" in result
        _reset()


class TestFeedsList:

    def test_list_feeds_from_cli(self):
        _reset()
        from tools.pidif import feeds_list
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "1. Tech News (https://example.com/rss) - 5 unread\n2. Science (https://sci.com/rss) - 2 unread"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_list.invoke({})
            assert "Tech News" in result
            assert "Science" in result
        _reset()

    def test_list_feeds_empty_cli_fallback_to_file(self, tmp_path):
        _reset()
        from tools.pidif import feeds_list
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = ""

        feeds_data = [{"title": "Saved Feed", "url": "https://saved.com/rss"}]
        feeds_file = tmp_path / "feeds.json"
        feeds_file.write_text(json.dumps(feeds_data))

        with patch("tools.pidif.subprocess.run", return_value=mock_proc), \
             patch("tools.pidif._find_config_dir", return_value=tmp_path):
            result = feeds_list.invoke({})
            assert "Saved Feed" in result
        _reset()

    def test_list_feeds_empty_no_file(self, tmp_path):
        _reset()
        from tools.pidif import feeds_list
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = ""

        with patch("tools.pidif.subprocess.run", return_value=mock_proc), \
             patch("tools.pidif._find_config_dir", return_value=tmp_path):
            result = feeds_list.invoke({})
            assert "no subscribed feeds" in result
        _reset()


class TestFeedsArticles:

    def test_articles_all_feeds(self):
        _reset()
        from tools.pidif import feeds_articles
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "1. Article One (2025-01-01)\n2. Article Two (2025-01-02)"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_articles.invoke({})
            assert "Article One" in result
        _reset()

    def test_articles_by_feed_url(self):
        _reset()
        from tools.pidif import feeds_articles
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "1. Specific Article"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc) as mock_run:
            result = feeds_articles.invoke({"feed_url": "https://example.com/rss"})
            assert "Specific Article" in result
            call_args = mock_run.call_args[0][0]
            assert "--feed" in call_args
        _reset()

    def test_articles_empty(self):
        _reset()
        from tools.pidif import feeds_articles
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = ""

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_articles.invoke({})
            assert "no articles found" in result
        _reset()

    def test_articles_timeout(self):
        _reset()
        from tools.pidif import feeds_articles
        import subprocess
        with patch("tools.pidif.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="pidif", timeout=15)):
            result = feeds_articles.invoke({})
            assert "timed out" in result
        _reset()


class TestFeedsRead:

    def test_read_by_article_id(self):
        _reset()
        from tools.pidif import feeds_read
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Full article text content here..."

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_read.invoke({"article_id": "art-123"})
            assert "Full article text" in result
        _reset()

    def test_read_by_article_url(self):
        _reset()
        from tools.pidif import feeds_read
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Article from URL"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc) as mock_run:
            result = feeds_read.invoke({"article_url": "https://example.com/article/1"})
            assert "Article from URL" in result
            call_args = mock_run.call_args[0][0]
            assert "--url" in call_args
        _reset()

    def test_read_no_identifier(self):
        _reset()
        from tools.pidif import feeds_read
        result = feeds_read.invoke({})
        assert "Error" in result or "provide" in result
        _reset()

    def test_read_article_not_found(self):
        _reset()
        from tools.pidif import feeds_read
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = ""

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_read.invoke({"article_id": "missing"})
            assert "not found" in result or "empty" in result
        _reset()


class TestFeedsSearch:

    def test_search_returns_results(self):
        _reset()
        from tools.pidif import feeds_search
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "1. AI Breakthrough in 2025\n2. AI Ethics Report"

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_search.invoke({"query": "AI"})
            assert "AI Breakthrough" in result
        _reset()

    def test_search_no_results(self):
        _reset()
        from tools.pidif import feeds_search
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = ""

        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            result = feeds_search.invoke({"query": "xyzzy"})
            assert "no articles matching" in result
        _reset()


class TestRegistryIntegration:

    def test_pidif_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "feeds_add" in _ALLOWED_EXPOSED_TOOLS
        assert "feeds_list" in _ALLOWED_EXPOSED_TOOLS
        assert "feeds_articles" in _ALLOWED_EXPOSED_TOOLS
        assert "feeds_read" in _ALLOWED_EXPOSED_TOOLS
        assert "feeds_search" in _ALLOWED_EXPOSED_TOOLS
