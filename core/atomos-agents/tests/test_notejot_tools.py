"""
Tests for the Notejot notes adapter (tools/notejot.py).

Covers:
  - Tool registration and discovery via get_notejot_tools()
  - Tool names and argument schemas
  - CRUD operations on the JSON note store
  - Search with relevance ranking
  - Error handling
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch
from pathlib import Path

from tools.app_adapter import DBusError


def _reset():
    import tools.notejot as mod
    mod._adapter = None
    mod._NOTEJOT_TOOLS = None


class TestNotejotToolRegistration:

    def test_get_notejot_tools_returns_six(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/notejot"):
            from tools.notejot import get_notejot_tools
            result = get_notejot_tools()
            assert len(result) == 6
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/notejot"):
            from tools.notejot import get_notejot_tools
            names = {t.name for t in get_notejot_tools()}
            assert names == {"notes_create", "notes_list", "notes_read", "notes_update", "notes_delete", "notes_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        mock_path = MagicMock()
        mock_path.exists.return_value = False
        with patch("shutil.which", return_value=None), \
             patch("tools.notejot._find_notes_file", return_value=mock_path):
            from tools.notejot import get_notejot_tools
            result = get_notejot_tools()
            assert result == []
        _reset()

    def test_returns_tools_when_data_file_exists(self):
        _reset()
        mock_path = MagicMock()
        mock_path.exists.return_value = True
        with patch("shutil.which", return_value=None), \
             patch("tools.notejot._find_notes_file", return_value=mock_path):
            from tools.notejot import get_notejot_tools
            result = get_notejot_tools()
            assert len(result) == 6
        _reset()


class TestNotesCreate:

    def test_create_note(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_create
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_create.invoke({"title": "My Note", "content": "Hello world"})
            assert "Note created" in result
            assert "My Note" in result
            assert "id=" in result

            saved = json.loads(notes_file.read_text())
            assert len(saved) == 1
            assert saved[0]["title"] == "My Note"
            assert saved[0]["content"] == "Hello world"
        _reset()

    def test_create_note_with_color(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_create
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_create.invoke({"title": "Colored", "content": "Red note", "color": "red"})
            assert "Note created" in result

            saved = json.loads(notes_file.read_text())
            assert saved[0]["color"] == "red"
        _reset()

    def test_create_appends_to_existing(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        existing = [{"id": "abc", "title": "Old", "content": "Old note", "color": "default", "created": 0, "modified": 0}]
        notes_file.write_text(json.dumps(existing))

        from tools.notejot import notes_create
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_create.invoke({"title": "New", "content": "New note"})
            assert "Note created" in result

            saved = json.loads(notes_file.read_text())
            assert len(saved) == 2
        _reset()


class TestNotesList:

    def test_list_notes(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [
            {"id": "a1", "title": "First", "content": "Content 1", "color": "blue", "created": 100, "modified": 200},
            {"id": "b2", "title": "Second", "content": "Content 2", "color": "default", "created": 50, "modified": 300},
        ]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_list
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_list.invoke({"limit": 50})
            parsed = json.loads(result)
            assert len(parsed) == 2
            assert parsed[0]["title"] == "Second"  # higher modified time
        _reset()

    def test_list_empty(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_list
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_list.invoke({"limit": 50})
            assert "no notes" in result
        _reset()

    def test_list_no_file(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"

        from tools.notejot import notes_list
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_list.invoke({"limit": 50})
            assert "no notes" in result
        _reset()


class TestNotesRead:

    def test_read_existing_note(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [{"id": "abc", "title": "Test", "content": "Full content here", "color": "default", "created": 0, "modified": 0}]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_read
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_read.invoke({"note_id": "abc"})
            parsed = json.loads(result)
            assert parsed["title"] == "Test"
            assert parsed["content"] == "Full content here"
        _reset()

    def test_read_not_found(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_read
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_read.invoke({"note_id": "missing"})
            assert "not found" in result
        _reset()


class TestNotesUpdate:

    def test_update_title(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [{"id": "abc", "title": "Old Title", "content": "Content", "color": "default", "created": 0, "modified": 0}]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_update
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_update.invoke({"note_id": "abc", "title": "New Title"})
            assert "Note updated" in result

            saved = json.loads(notes_file.read_text())
            assert saved[0]["title"] == "New Title"
            assert saved[0]["content"] == "Content"  # unchanged
        _reset()

    def test_update_content(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [{"id": "abc", "title": "Title", "content": "Old content", "color": "default", "created": 0, "modified": 0}]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_update
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_update.invoke({"note_id": "abc", "content": "Updated content"})
            assert "Note updated" in result

            saved = json.loads(notes_file.read_text())
            assert saved[0]["content"] == "Updated content"
            assert saved[0]["modified"] > 0
        _reset()

    def test_update_not_found(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_update
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_update.invoke({"note_id": "missing", "title": "New"})
            assert "not found" in result
        _reset()


class TestNotesDelete:

    def test_delete_note(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [
            {"id": "abc", "title": "Delete Me", "content": "...", "color": "default", "created": 0, "modified": 0},
            {"id": "def", "title": "Keep Me", "content": "...", "color": "default", "created": 0, "modified": 0},
        ]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_delete
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_delete.invoke({"note_id": "abc"})
            assert "Note deleted" in result

            saved = json.loads(notes_file.read_text())
            assert len(saved) == 1
            assert saved[0]["id"] == "def"
        _reset()

    def test_delete_not_found(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        from tools.notejot import notes_delete
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_delete.invoke({"note_id": "missing"})
            assert "not found" in result
        _reset()


class TestNotesSearch:

    def test_search_by_title(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [
            {"id": "a1", "title": "Meeting Notes", "content": "Discussed project", "color": "default", "created": 0, "modified": 0},
            {"id": "b2", "title": "Shopping List", "content": "Buy groceries", "color": "default", "created": 0, "modified": 0},
        ]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_search
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_search.invoke({"query": "Meeting"})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["title"] == "Meeting Notes"
        _reset()

    def test_search_by_content(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [
            {"id": "a1", "title": "Note A", "content": "Contains the keyword python here", "color": "default", "created": 0, "modified": 0},
            {"id": "b2", "title": "Note B", "content": "No match here", "color": "default", "created": 0, "modified": 0},
        ]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_search
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_search.invoke({"query": "python"})
            parsed = json.loads(result)
            assert len(parsed) == 1
            assert parsed[0]["id"] == "a1"
        _reset()

    def test_search_no_results(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [{"id": "a1", "title": "Note", "content": "Content", "color": "default", "created": 0, "modified": 0}]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_search
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_search.invoke({"query": "xyzzy"})
            assert "no notes matching" in result
        _reset()

    def test_search_title_ranked_higher(self, tmp_path):
        _reset()
        notes_file = tmp_path / "notes.json"
        notes = [
            {"id": "a1", "title": "Note A", "content": "Contains python in body", "color": "default", "created": 0, "modified": 0},
            {"id": "b2", "title": "Python Guide", "content": "The full python tutorial", "color": "default", "created": 0, "modified": 0},
        ]
        notes_file.write_text(json.dumps(notes))

        from tools.notejot import notes_search
        with patch("tools.notejot._find_notes_file", return_value=notes_file), \
             patch("tools.notejot._find_data_dir", return_value=tmp_path):
            result = notes_search.invoke({"query": "python"})
            parsed = json.loads(result)
            assert len(parsed) == 2
            assert parsed[0]["id"] == "b2"  # title match ranks higher
        _reset()


class TestRegistryIntegration:

    def test_notejot_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "notes_create" in _ALLOWED_EXPOSED_TOOLS
        assert "notes_list" in _ALLOWED_EXPOSED_TOOLS
        assert "notes_read" in _ALLOWED_EXPOSED_TOOLS
        assert "notes_update" in _ALLOWED_EXPOSED_TOOLS
        assert "notes_delete" in _ALLOWED_EXPOSED_TOOLS
        assert "notes_search" in _ALLOWED_EXPOSED_TOOLS
