"""
Tests for the Loupe image viewer adapter (tools/loupe.py).

Covers:
  - Tool registration and discovery via get_loupe_tools()
  - Tool names and argument schemas
  - image_open via D-Bus and CLI fallbacks
  - image_metadata with PIL and fallback extraction
  - Error handling
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch
from pathlib import Path

from tools.app_adapter import DBusError


def _reset():
    import tools.loupe as mod
    mod._adapter = None
    mod._LOUPE_TOOLS = None


class TestLoupeToolRegistration:

    def test_get_loupe_tools_returns_two(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/loupe"):
            from tools.loupe import get_loupe_tools
            result = get_loupe_tools()
            assert len(result) == 2
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/loupe"):
            from tools.loupe import get_loupe_tools
            names = {t.name for t in get_loupe_tools()}
            assert names == {"image_open", "image_metadata"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.loupe import get_loupe_tools
            result = get_loupe_tools()
            assert result == []
        _reset()


class TestImageOpen:

    def test_open_via_dbus(self, tmp_path):
        _reset()
        img_file = tmp_path / "photo.png"
        img_file.write_bytes(b"\x89PNG" + b"\x00" * 100)

        from tools.loupe import image_open, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = image_open.invoke({"file_path": str(img_file)})
            assert "Opened in Loupe" in result
        _reset()

    def test_open_cli_fallback(self, tmp_path):
        _reset()
        img_file = tmp_path / "photo.png"
        img_file.write_bytes(b"\x89PNG" + b"\x00" * 100)

        from tools.loupe import image_open, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no bus")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.Popen") as mock_popen:
            result = image_open.invoke({"file_path": str(img_file)})
            assert "Opened in Loupe" in result
            assert "CLI" in result
        _reset()

    def test_open_xdg_fallback(self, tmp_path):
        _reset()
        img_file = tmp_path / "photo.png"
        img_file.write_bytes(b"\x89PNG" + b"\x00" * 100)

        from tools.loupe import image_open, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("no bus")
        adapter._dbus = mock_dbus

        def popen_side_effect(args, **kwargs):
            if args[0] == "loupe":
                raise FileNotFoundError("loupe not found")
            return MagicMock()

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.Popen", side_effect=popen_side_effect):
            result = image_open.invoke({"file_path": str(img_file)})
            assert "default viewer" in result
        _reset()

    def test_open_file_not_found(self):
        _reset()
        from tools.loupe import image_open
        result = image_open.invoke({"file_path": "/nonexistent/photo.png"})
        assert "File not found" in result
        _reset()

    def test_open_not_a_file(self, tmp_path):
        _reset()
        from tools.loupe import image_open
        result = image_open.invoke({"file_path": str(tmp_path)})
        assert "Not a file" in result
        _reset()


class TestImageMetadata:

    def test_metadata_with_pil(self, tmp_path):
        _reset()
        img_file = tmp_path / "test.jpg"
        img_file.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 100)

        mock_img = MagicMock()
        mock_img.format = "JPEG"
        mock_img.width = 1920
        mock_img.height = 1080
        mock_img.mode = "RGB"
        mock_img.getexif.return_value = {}
        mock_img.__enter__ = MagicMock(return_value=mock_img)
        mock_img.__exit__ = MagicMock(return_value=False)

        mock_image_mod = MagicMock()
        mock_image_mod.open.return_value = mock_img

        import sys
        mock_pil = MagicMock()
        mock_pil.Image = mock_image_mod
        mock_exif_tags = MagicMock()
        mock_exif_tags.TAGS = {}
        mock_pil.ExifTags = mock_exif_tags
        with patch.dict(sys.modules, {"PIL": mock_pil, "PIL.Image": mock_image_mod, "PIL.ExifTags": mock_exif_tags}):
            from tools.loupe import image_metadata
            with patch("tools.loupe.Path") as mock_path_cls:
                mock_path = MagicMock()
                mock_path.exists.return_value = True
                mock_path.stat.return_value = MagicMock(st_size=104)
                mock_path.suffix = ".jpg"
                mock_path_cls.return_value.expanduser.return_value.resolve.return_value = mock_path

                result = image_metadata.invoke({"file_path": str(img_file)})
                parsed = json.loads(result)
                assert parsed["format"] == "JPEG"
                assert parsed["width"] == 1920
                assert parsed["height"] == 1080
        _reset()

    def test_metadata_file_not_found(self):
        _reset()
        from tools.loupe import image_metadata
        result = image_metadata.invoke({"file_path": "/nonexistent/test.jpg"})
        assert "File not found" in result
        _reset()

    def test_metadata_fallback_to_file_command(self, tmp_path):
        _reset()
        img_file = tmp_path / "test.webp"
        img_file.write_bytes(b"RIFF" + b"\x00" * 100)

        from tools.loupe import image_metadata
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "image/webp"

        import builtins
        real_import = builtins.__import__
        def fail_pil(name, *args, **kwargs):
            if name == "PIL" or name.startswith("PIL."):
                raise ImportError("no PIL")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=fail_pil), \
             patch("shutil.which", return_value=None), \
             patch("subprocess.run", return_value=mock_proc):
            result = image_metadata.invoke({"file_path": str(img_file)})
            parsed = json.loads(result)
            assert parsed["size_bytes"] == 104
        _reset()


class TestRegistryIntegration:

    def test_loupe_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "image_open" in _ALLOWED_EXPOSED_TOOLS
        assert "image_metadata" in _ALLOWED_EXPOSED_TOOLS
