"""
Unit tests for editor/filesystem tools and Zed integration.

- editor.py: open_in_editor, read_file, edit_file, create_file, search_in_files
"""
import os
import tempfile

import pytest
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# _sanitize_path — LLM path mangling cleanup
# ---------------------------------------------------------------------------


class TestSanitizePath:
    def test_returns_clean_path_unchanged(self):
        from tools.editor import _sanitize_path
        assert _sanitize_path("/home/atom/file.py") == "/home/atom/file.py"

    def test_strips_whitespace(self):
        from tools.editor import _sanitize_path
        assert _sanitize_path("  /home/atom/file.py  ") == "/home/atom/file.py"

    def test_picks_last_absolute_path_from_concatenation(self):
        from tools.editor import _sanitize_path
        result = _sanitize_path("/opt/atomos/agents/src/ /home/atom/solve_quadratic.py")
        assert result == "/home/atom/solve_quadratic.py"

    def test_picks_tilde_path_from_concatenation(self):
        from tools.editor import _sanitize_path
        result = _sanitize_path("/some/dir ~/projects/code.rs")
        assert result == "~/projects/code.rs"

    def test_relative_path_returned_as_is(self):
        from tools.editor import _sanitize_path
        assert _sanitize_path("src/main.py") == "src/main.py"


# ---------------------------------------------------------------------------
# open_in_editor
# ---------------------------------------------------------------------------


class TestOpenInEditor:
    def test_opens_existing_file_with_zed(self, tmp_path):
        target = tmp_path / "main.py"
        target.write_text("print('hello')")

        with (
            patch("tools.editor.subprocess.Popen") as mock_popen,
            patch("tools.editor.shutil.which", side_effect=lambda n: "/usr/local/bin/zed" if n == "zed" else None),
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": str(target)})

        assert "Opened file in zed" in result
        mock_popen.assert_called_once()

    def test_opens_existing_directory(self, tmp_path):
        with (
            patch("tools.editor.subprocess.Popen") as mock_popen,
            patch("tools.editor.shutil.which", side_effect=lambda n: "/usr/local/bin/zed" if n == "zed" else None),
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": str(tmp_path)})

        assert "Opened directory in zed" in result
        mock_popen.assert_called_once()

    def test_returns_error_for_nonexistent_path(self):
        from tools.editor import open_in_editor
        result = open_in_editor.invoke({"path": "/nonexistent/path/xyz"})
        assert "does not exist" in result

    def test_falls_back_to_vscode_when_zed_missing(self, tmp_path):
        target = tmp_path / "test.py"
        target.write_text("x = 1")

        def which_side_effect(name):
            return "/usr/bin/code" if name == "code" else None

        with (
            patch("tools.editor.subprocess.Popen") as mock_popen,
            patch("tools.editor.shutil.which", side_effect=which_side_effect),
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": str(target)})

        assert "Opened file in code" in result

    def test_falls_back_to_os_default_when_no_editor(self, tmp_path):
        target = tmp_path / "test.py"
        target.write_text("x = 1")

        with (
            patch("tools.editor.shutil.which", return_value=None),
            patch("tools.editor._platform_open", return_value=True) as mock_open,
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": str(target)})

        assert "system default handler" in result
        mock_open.assert_called_once()

    def test_returns_guidance_when_nothing_available(self, tmp_path):
        target = tmp_path / "test.py"
        target.write_text("x = 1")

        with (
            patch("tools.editor.shutil.which", return_value=None),
            patch("tools.editor._platform_open", return_value=False),
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": str(target)})

        assert "No editor found" in result
        assert "zed.dev" in result

    def test_sanitizes_concatenated_path(self, tmp_path):
        target = tmp_path / "real_file.py"
        target.write_text("y = 2")

        bad_path = f"/opt/atomos/agents/src/ {target}"

        with (
            patch("tools.editor.subprocess.Popen") as mock_popen,
            patch("tools.editor.shutil.which", side_effect=lambda n: "/usr/local/bin/zed" if n == "zed" else None),
        ):
            from tools.editor import open_in_editor
            result = open_in_editor.invoke({"path": bad_path})

        assert "Opened file in zed" in result
        assert str(target) in result


# ---------------------------------------------------------------------------
# read_file
# ---------------------------------------------------------------------------


class TestReadFile:
    def test_reads_entire_file(self, tmp_path):
        target = tmp_path / "data.txt"
        target.write_text("line1\nline2\nline3")

        from tools.editor import read_file
        result = read_file.invoke({"file_path": str(target)})

        assert "1|line1" in result
        assert "2|line2" in result
        assert "3|line3" in result

    def test_reads_with_offset_and_limit(self, tmp_path):
        target = tmp_path / "data.txt"
        target.write_text("a\nb\nc\nd\ne")

        from tools.editor import read_file
        result = read_file.invoke({
            "file_path": str(target),
            "offset": 2,
            "limit": 2,
        })

        assert "2|b" in result
        assert "3|c" in result
        assert "1|a" not in result
        assert "4|d" not in result

    def test_returns_error_for_nonexistent_file(self):
        from tools.editor import read_file
        result = read_file.invoke({"file_path": "/nonexistent/file.txt"})
        assert "not found" in result.lower()

    def test_empty_file_returns_empty_marker(self, tmp_path):
        target = tmp_path / "empty.txt"
        target.write_text("")

        from tools.editor import read_file
        result = read_file.invoke({"file_path": str(target)})
        assert "empty" in result.lower()


# ---------------------------------------------------------------------------
# edit_file
# ---------------------------------------------------------------------------


class TestEditFile:
    def test_replaces_exact_text(self, tmp_path):
        target = tmp_path / "code.py"
        target.write_text("def hello():\n    return 'world'\n")

        from tools.editor import edit_file
        result = edit_file.invoke({
            "file_path": str(target),
            "old_text": "return 'world'",
            "new_text": "return 'universe'",
        })

        assert "Successfully edited" in result
        assert "return 'universe'" in target.read_text()

    def test_only_replaces_first_occurrence(self, tmp_path):
        target = tmp_path / "dup.txt"
        target.write_text("aaa\naaa\naaa")

        from tools.editor import edit_file
        edit_file.invoke({
            "file_path": str(target),
            "old_text": "aaa",
            "new_text": "bbb",
        })

        content = target.read_text()
        assert content == "bbb\naaa\naaa"

    def test_returns_error_when_text_not_found(self, tmp_path):
        target = tmp_path / "code.py"
        target.write_text("x = 1")

        from tools.editor import edit_file
        result = edit_file.invoke({
            "file_path": str(target),
            "old_text": "NOT_HERE",
            "new_text": "replacement",
        })

        assert "not found" in result.lower()
        assert target.read_text() == "x = 1"

    def test_returns_error_for_nonexistent_file(self):
        from tools.editor import edit_file
        result = edit_file.invoke({
            "file_path": "/nonexistent/file.py",
            "old_text": "a",
            "new_text": "b",
        })
        assert "not found" in result.lower()


# ---------------------------------------------------------------------------
# create_file
# ---------------------------------------------------------------------------


class TestCreateFile:
    def test_creates_file_with_contents(self, tmp_path):
        target = tmp_path / "new_file.txt"

        from tools.editor import create_file
        result = create_file.invoke({
            "file_path": str(target),
            "contents": "hello world",
        })

        assert "Created" in result
        assert target.read_text() == "hello world"

    def test_creates_parent_directories(self, tmp_path):
        target = tmp_path / "deep" / "nested" / "file.txt"

        from tools.editor import create_file
        result = create_file.invoke({
            "file_path": str(target),
            "contents": "nested content",
        })

        assert "Created" in result
        assert target.read_text() == "nested content"

    def test_refuses_to_overwrite_existing_file(self, tmp_path):
        target = tmp_path / "existing.txt"
        target.write_text("original")

        from tools.editor import create_file
        result = create_file.invoke({
            "file_path": str(target),
            "contents": "replacement",
        })

        assert "already exists" in result
        assert target.read_text() == "original"


# ---------------------------------------------------------------------------
# search_in_files
# ---------------------------------------------------------------------------


class TestSearchInFiles:
    def test_finds_matching_lines(self, tmp_path):
        (tmp_path / "a.py").write_text("def foo():\n    pass\n")
        (tmp_path / "b.py").write_text("def bar():\n    foo()\n")

        with patch("tools.editor.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="a.py:1:def foo():\nb.py:2:    foo()\n",
                returncode=0,
            )
            from tools.editor import search_in_files
            result = search_in_files.invoke({
                "pattern": "foo",
                "directory": str(tmp_path),
            })

        assert "foo" in result

    def test_returns_no_matches_message(self, tmp_path):
        with patch("tools.editor.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="", returncode=1)
            from tools.editor import search_in_files
            result = search_in_files.invoke({
                "pattern": "NONEXISTENT_PATTERN_XYZ",
                "directory": str(tmp_path),
            })

        assert "No matches" in result

    def test_passes_file_glob(self, tmp_path):
        with patch("tools.editor.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="", returncode=1)
            from tools.editor import search_in_files
            search_in_files.invoke({
                "pattern": "test",
                "directory": str(tmp_path),
                "file_glob": "*.py",
            })

        call_args = mock_run.call_args[0][0]
        assert "--glob" in call_args
        assert "*.py" in call_args

    def test_returns_error_for_nonexistent_directory(self):
        from tools.editor import search_in_files
        result = search_in_files.invoke({
            "pattern": "test",
            "directory": "/nonexistent/dir/xyz",
        })
        assert "not found" in result.lower()

    def test_returns_error_when_rg_not_installed(self, tmp_path):
        with patch("tools.editor.subprocess.run", side_effect=FileNotFoundError):
            from tools.editor import search_in_files
            result = search_in_files.invoke({
                "pattern": "test",
                "directory": str(tmp_path),
            })

        assert "not installed" in result


# ---------------------------------------------------------------------------
# get_editor_tools — tool discovery
# ---------------------------------------------------------------------------


class TestGetEditorTools:
    def test_returns_five_tools(self):
        from tools.editor import get_editor_tools
        tools = get_editor_tools()
        assert len(tools) == 5

    def test_tool_names(self):
        from tools.editor import get_editor_tools
        names = {t.name for t in get_editor_tools()}
        assert names == {
            "open_in_editor",
            "read_file",
            "edit_file",
            "create_file",
            "search_in_files",
        }

    def test_all_tools_have_descriptions(self):
        from tools.editor import get_editor_tools
        for tool in get_editor_tools():
            assert tool.description, f"Tool {tool.name} has no description"


# ---------------------------------------------------------------------------
# skills.py — editor tools included in atomos skills
# ---------------------------------------------------------------------------


class TestAtomosSkillsIncludeEditorTools:
    def test_get_atomos_skills_includes_editor_tools(self):
        with (
            patch("tools.browser.run_local_browser_task"),
            patch("tools.browser.run_local_browser_session"),
            patch("tools.browser.run_cloud_browser_task"),
            patch("tools.browser.run_cloud_browser_session"),
        ):
            from tools.skills import get_atomos_skills
            skills = get_atomos_skills()
            names = {getattr(t, "name", "") for t in skills}
            assert "open_in_editor" in names
            assert "edit_file" in names
            assert "read_file" in names
            assert "create_file" in names
            assert "search_in_files" in names
