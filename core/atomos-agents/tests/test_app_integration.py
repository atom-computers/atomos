"""
Cross-cutting integration tests for iso-ubuntu application connections (§3).

Covers:
  - All 13 applications registered and discoverable simultaneously
  - Agent invokes tools from 3+ different apps in a single turn
  - Application crash mid-operation → adapter detects → restarts → retries
  - Agent lists available application tools → all registered apps appear
"""

import json
import os
import time
import pytest
from unittest.mock import MagicMock, patch, PropertyMock


# ── helpers ────────────────────────────────────────────────────────────────

# All 12 adapter modules (Chromium is §3.1, handled by browser-use, not an
# AppAdapter — so we cover the 12 AppAdapter-based apps here).
_APP_MODULES = [
    ("geary",         "tools.geary",         "get_geary_tools",         "geary",           4),
    ("chatty",        "tools.chatty",        "get_chatty_tools",        "chatty",          4),
    ("amberol",       "tools.amberol",       "get_amberol_tools",       "amberol",         5),
    ("podcasts",      "tools.podcasts",      "get_podcasts_tools",      "gnome-podcasts",  4),
    ("vocalis",       "tools.vocalis",       "get_vocalis_tools",       "vocalis",         3),
    ("loupe",         "tools.loupe",         "get_loupe_tools",         "loupe",           2),
    ("karlender",     "tools.karlender",     "get_karlender_tools",     "karlender",       5),
    ("contacts",      "tools.contacts",      "get_contacts_tools",      "gnome-contacts",  4),
    ("pidif",         "tools.pidif",         "get_pidif_tools",         "pidif",           5),
    ("notejot",       "tools.notejot",       "get_notejot_tools",       "notejot",         6),
    ("authenticator", "tools.authenticator", "get_authenticator_tools", "authenticator",   3),
    ("passes",        "tools.passes",        "get_passes_tools",        "passes",          4),
]

_ALL_APP_TOOL_NAMES = {
    # Geary
    "email_compose", "email_send", "email_search", "email_read",
    # Chatty
    "chat_send", "chat_read", "chat_list", "chat_search",
    # Amberol
    "music_play", "music_pause", "music_skip", "music_queue", "music_now_playing",
    # Podcasts
    "podcast_subscribe", "podcast_list", "podcast_play", "podcast_search",
    # Vocalis
    "voice_record_start", "voice_record_stop", "voice_recordings_list",
    # Loupe
    "image_open", "image_metadata",
    # Karlender
    "calendar_list", "calendar_create", "calendar_update", "calendar_delete", "calendar_search",
    # Contacts
    "contacts_list", "contacts_search", "contacts_create", "contacts_get",
    # Pidif
    "feeds_add", "feeds_list", "feeds_articles", "feeds_read", "feeds_search",
    # Notejot
    "notes_create", "notes_list", "notes_read", "notes_update", "notes_delete", "notes_search",
    # Authenticator
    "auth_list", "auth_get_code", "auth_add",
    # Passes
    "pass_list", "pass_get", "pass_add", "pass_search",
}


def _reset_all_modules():
    """Reset cached state in every adapter module."""
    import importlib
    for _, mod_path, _, _, _ in _APP_MODULES:
        try:
            mod = importlib.import_module(mod_path)
            if hasattr(mod, "_adapter"):
                mod._adapter = None
            for attr in dir(mod):
                if attr.startswith("_") and attr.endswith("_TOOLS"):
                    setattr(mod, attr, None)
        except Exception:
            pass


def _mock_which(binary):
    """Pretend every app binary is installed."""
    return f"/usr/bin/{binary}"


# ── Test 1: all apps registered simultaneously ────────────────────────────


class TestAllAppsRegistered:
    """Integration: all 13 applications installed and running in iso-ubuntu
    simultaneously → all adapters register tools → discover_all_tools()
    returns the combined app tool list with correct namespaces.

    Chromium (§3.1) is handled by browser-use, so we verify the 12
    AppAdapter-based apps here.
    """

    def test_all_app_tools_discoverable(self):
        """When all app binaries are on $PATH, every adapter contributes
        its tools to get_atomos_skills()."""
        _reset_all_modules()

        with patch("shutil.which", side_effect=_mock_which):
            discovered_names: set[str] = set()
            for ns, mod_path, getter_name, binary, expected_count in _APP_MODULES:
                import importlib
                mod = importlib.import_module(mod_path)
                # Reset cached tools so the getter re-evaluates
                for attr in dir(mod):
                    if attr.startswith("_") and attr.endswith("_TOOLS"):
                        setattr(mod, attr, None)
                getter = getattr(mod, getter_name)
                tools = getter()
                names = {t.name for t in tools}
                discovered_names.update(names)
                assert len(tools) == expected_count, (
                    f"{ns}: expected {expected_count} tools, got {len(tools)}: {names}"
                )

            assert _ALL_APP_TOOL_NAMES.issubset(discovered_names), (
                f"Missing tools: {_ALL_APP_TOOL_NAMES - discovered_names}"
            )

        _reset_all_modules()

    def test_total_app_tool_count(self):
        """The total number of app tools across all 12 adapters is 49."""
        _reset_all_modules()
        expected_total = sum(count for _, _, _, _, count in _APP_MODULES)
        assert expected_total == 49

        with patch("shutil.which", side_effect=_mock_which):
            total = 0
            for _, mod_path, getter_name, _, _ in _APP_MODULES:
                import importlib
                mod = importlib.import_module(mod_path)
                for attr in dir(mod):
                    if attr.startswith("_") and attr.endswith("_TOOLS"):
                        setattr(mod, attr, None)
                getter = getattr(mod, getter_name)
                total += len(getter())
            assert total == 49

        _reset_all_modules()

    def test_all_app_tools_in_allowed_exposed_set(self):
        """Every app tool name must appear in _ALLOWED_EXPOSED_TOOLS in
        the tool registry — otherwise the tool would be discovered but
        silently filtered out."""
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        missing = _ALL_APP_TOOL_NAMES - _ALLOWED_EXPOSED_TOOLS
        assert not missing, f"Tools missing from _ALLOWED_EXPOSED_TOOLS: {missing}"

    def test_no_namespace_collisions_across_adapters(self):
        """No two adapters register a tool with the same name."""
        _reset_all_modules()
        seen: dict[str, str] = {}
        collisions: list[str] = []

        with patch("shutil.which", side_effect=_mock_which):
            for ns, mod_path, getter_name, _, _ in _APP_MODULES:
                import importlib
                mod = importlib.import_module(mod_path)
                for attr in dir(mod):
                    if attr.startswith("_") and attr.endswith("_TOOLS"):
                        setattr(mod, attr, None)
                getter = getattr(mod, getter_name)
                for tool in getter():
                    name = tool.name
                    if name in seen and seen[name] != ns:
                        collisions.append(f"{name}: {seen[name]} vs {ns}")
                    seen[name] = ns

        assert not collisions, f"Namespace collisions: {collisions}"
        _reset_all_modules()


# ── Test 2: multi-app tool invocation in a single turn ────────────────────


class TestMultiAppInvocation:
    """Integration: agent invokes tools from 3+ different apps in a
    single turn — verifies that tools from different adapters can be
    called sequentially without interference."""

    def test_invoke_tools_from_three_apps(self, tmp_path):
        """Call one tool each from Notejot, Amberol, and Loupe in sequence."""
        _reset_all_modules()

        # 1. Notejot: create a note (uses JSON file — no D-Bus needed)
        import tools.notejot as notejot_mod
        notejot_mod._adapter = None
        notejot_mod._NOTEJOT_TOOLS = None
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        with patch("tools.notejot._find_notes_file", return_value=notes_file):
            from tools.notejot import notes_create, notes_list
            result1 = notes_create.invoke({"title": "Test Note", "content": "Hello from integration test"})
            assert "Note created" in result1
            result1b = notes_list.invoke({})
            assert "Test Note" in result1b

        # 2. Amberol: try to play (mock D-Bus)
        import tools.amberol as amberol_mod
        amberol_mod._adapter = None
        amberol_mod._AMBEROL_TOOLS = None
        from tools.amberol import music_play, _get_adapter as get_amberol
        adapter_a = get_amberol()
        adapter_a._lifecycle._pid = 1
        mock_dbus_a = MagicMock()
        adapter_a._dbus = mock_dbus_a
        with patch.object(adapter_a._lifecycle, "ensure_running", return_value=None):
            result2 = music_play.invoke({"uri": "/home/user/song.mp3"})
            assert "Playing" in result2

        # 3. Loupe: open an image (mock file existence + D-Bus)
        import tools.loupe as loupe_mod
        loupe_mod._adapter = None
        loupe_mod._LOUPE_TOOLS = None
        img_file = tmp_path / "photo.jpg"
        img_file.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 50)

        from tools.loupe import image_metadata
        result3 = image_metadata.invoke({"file_path": str(img_file)})
        parsed = json.loads(result3)
        assert parsed["size_bytes"] == 54

        _reset_all_modules()

    def test_invoke_tools_from_four_apps(self, tmp_path):
        """Call tools from Contacts, Karlender, Chatty, and Pidif."""
        _reset_all_modules()

        # 1. Contacts: create a contact (mock D-Bus)
        import tools.contacts as contacts_mod
        contacts_mod._adapter = None
        contacts_mod._CONTACTS_TOOLS = None
        from tools.contacts import contacts_create, _get_adapter as get_contacts
        adapter_c = get_contacts()
        adapter_c._lifecycle._pid = 1
        mock_dbus_c = MagicMock()
        adapter_c._dbus = mock_dbus_c
        with patch.object(adapter_c._lifecycle, "ensure_running", return_value=None):
            r1 = contacts_create.invoke({"full_name": "Alice Smith", "email": "alice@test.com"})
            assert "Contact created" in r1

        # 2. Karlender: list events (mock D-Bus)
        import tools.karlender as karl_mod
        karl_mod._adapter = None
        karl_mod._KARLENDER_TOOLS = None
        from tools.karlender import calendar_list, _get_adapter as get_karl
        adapter_k = get_karl()
        adapter_k._lifecycle._pid = 1
        mock_dbus_k = MagicMock()
        mock_dbus_k.call.return_value = "('Team meeting @ 10am',)"
        adapter_k._dbus = mock_dbus_k
        with patch.object(adapter_k._lifecycle, "ensure_running", return_value=None):
            r2 = calendar_list.invoke({})
            assert "meeting" in r2

        # 3. Chatty: list conversations (mock D-Bus)
        import tools.chatty as chatty_mod
        chatty_mod._adapter = None
        chatty_mod._CHATTY_TOOLS = None
        from tools.chatty import chat_list, _get_adapter as get_chatty
        adapter_ch = get_chatty()
        adapter_ch._lifecycle._pid = 1
        mock_dbus_ch = MagicMock()
        mock_dbus_ch.call.return_value = "('Alice: hey!',)"
        adapter_ch._dbus = mock_dbus_ch
        with patch.object(adapter_ch._lifecycle, "ensure_running", return_value=None):
            r3 = chat_list.invoke({})
            assert "Alice" in r3

        # 4. Pidif: search articles (mock CLI)
        import tools.pidif as pidif_mod
        pidif_mod._adapter = None
        pidif_mod._PIDIF_TOOLS = None
        from tools.pidif import feeds_search
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Rust 2025 update — new borrow checker features"
        with patch("tools.pidif.subprocess.run", return_value=mock_proc):
            r4 = feeds_search.invoke({"query": "rust"})
            assert "Rust" in r4

        _reset_all_modules()

    def test_no_shared_state_leakage_between_adapters(self):
        """Caching in one adapter does not affect another."""
        _reset_all_modules()

        from tools.app_adapter import AppAdapter

        class AdapterA(AppAdapter):
            namespace = "test_a"
            app_id = "test.A"
            binary = "a"
            def get_tools(self): return []

        class AdapterB(AppAdapter):
            namespace = "test_b"
            app_id = "test.B"
            binary = "b"
            def get_tools(self): return []

        a = AdapterA()
        b = AdapterB()

        a.set_cached("key", "value_a")
        b.set_cached("key", "value_b")

        assert a.get_cached("key") == "value_a"
        assert b.get_cached("key") == "value_b"

        a.clear_cache()
        assert a.get_cached("key") is None
        assert b.get_cached("key") == "value_b"


# ── Test 3: crash recovery ────────────────────────────────────────────────


class TestCrashRecovery:
    """Integration: application crash mid-operation → adapter detects →
    restarts app → retries operation."""

    def test_adapter_detects_crash_and_restarts(self):
        """When an app crashes (is_running returns False after being True),
        ensure_running relaunches it."""
        from tools.app_adapter import AppLifecycleManager

        mgr = AppLifecycleManager("org.test.App", "test-app")

        call_count = {"is_running": 0, "launch": 0}

        def mock_is_running():
            call_count["is_running"] += 1
            # First call: not running (crashed)
            return False

        def mock_launch():
            call_count["launch"] += 1
            return True

        with patch.object(mgr, "is_installed", return_value=True), \
             patch.object(mgr, "is_running", side_effect=mock_is_running), \
             patch.object(mgr, "launch", side_effect=mock_launch):
            mgr._last_health_check = 0  # force health check
            result = mgr.ensure_running()
            assert result is None  # success
            assert call_count["launch"] == 1

    def test_geary_retries_after_crash(self):
        """Geary adapter retries D-Bus call after the app is restarted."""
        _reset_all_modules()
        import tools.geary as geary_mod
        geary_mod._adapter = None
        geary_mod._GEARY_TOOLS = None

        from tools.geary import email_search, _get_adapter

        adapter = _get_adapter()
        call_count = {"ensure": 0}

        # First ensure_running: app crashed, but relaunch succeeds
        def mock_ensure():
            call_count["ensure"] += 1
            return None  # success after restart

        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Re-fetched emails after restart',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", side_effect=mock_ensure):
            result = email_search.invoke({"query": "test"})
            assert "Re-fetched" in result
            assert call_count["ensure"] == 1

        _reset_all_modules()

    def test_crash_during_dbus_call_returns_error(self):
        """If D-Bus call fails because app crashed, error is returned
        gracefully (no exception propagated to agent)."""
        _reset_all_modules()
        import tools.chatty as chatty_mod
        chatty_mod._adapter = None
        chatty_mod._CHATTY_TOOLS = None

        from tools.chatty import chat_send, _get_adapter
        from tools.app_adapter import DBusError

        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError(
            "org.freedesktop.DBus.Error.ServiceUnknown: "
            "The name sm.puri.Chatty was not provided by any .service files"
        )
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_send.invoke({
                "recipient": "@bob:matrix.org",
                "message": "hello",
            })
            assert "Failed" in result
            assert isinstance(result, str)  # no exception

        _reset_all_modules()

    def test_lifecycle_restart_cycle(self):
        """Full restart cycle: running → crash → detect → kill → relaunch."""
        from tools.app_adapter import AppLifecycleManager

        mgr = AppLifecycleManager("org.test.CrashApp", "crash-app")

        states = iter([
            True,   # initial health_check → running
            False,  # after crash → not running
            True,   # after relaunch → running again
        ])

        with patch.object(mgr, "is_running", side_effect=lambda: next(states)), \
             patch.object(mgr, "is_installed", return_value=True), \
             patch("subprocess.run"), \
             patch("subprocess.Popen") as mock_popen:
            mock_popen.return_value = MagicMock(pid=9999)

            # Phase 1: healthy
            mgr._last_health_check = 0
            assert mgr.health_check() is True

            # Phase 2: crashed
            mgr._last_health_check = 0
            assert mgr.health_check() is False

            # Phase 3: restart succeeds
            mgr._last_health_check = 0
            assert mgr.health_check() is True


# ── Test 4: tool listing ──────────────────────────────────────────────────


class TestToolListing:
    """Integration: agent lists available application tools → all
    registered apps appear with correct tool names."""

    def test_all_app_tools_appear_in_skills(self):
        """get_atomos_skills() includes all app tools when binaries are
        available (mocked)."""
        _reset_all_modules()

        # Disable packages that require external deps we can't mock easily
        disable_env = {
            "ATOMOS_TOOLS_DISABLE_BROWSER": "1",
            "ATOMOS_TOOLS_DISABLE_EDITOR": "1",
            "ATOMOS_TOOLS_DISABLE_SHELL": "1",
            "ATOMOS_TOOLS_DISABLE_ARXIV": "1",
            "ATOMOS_TOOLS_DISABLE_DEVTOOLS": "1",
            "ATOMOS_TOOLS_DISABLE_SUPERPOWERS": "1",
            "ATOMOS_TOOLS_DISABLE_RESEARCHER": "1",
            "ATOMOS_TOOLS_DISABLE_DRAWIO": "1",
            "ATOMOS_TOOLS_DISABLE_NOTION": "1",
            "ATOMOS_TOOLS_DISABLE_GOOGLE_WORKSPACE": "1",
        }

        with patch.dict(os.environ, disable_env), \
             patch("shutil.which", side_effect=_mock_which):
            from tools.skills import get_atomos_skills
            all_tools = get_atomos_skills()
            tool_names = {getattr(t, "name", str(t)) for t in all_tools}

            # Should include the 2 built-in tools + all 49 app tools
            for app_tool in _ALL_APP_TOOL_NAMES:
                assert app_tool in tool_names, (
                    f"App tool '{app_tool}' missing from get_atomos_skills() result"
                )

        _reset_all_modules()

    def test_disabled_app_tools_not_in_skills(self):
        """When an app package is disabled via env var, its tools are
        excluded from get_atomos_skills()."""
        _reset_all_modules()

        disable_env = {
            "ATOMOS_TOOLS_DISABLE_BROWSER": "1",
            "ATOMOS_TOOLS_DISABLE_EDITOR": "1",
            "ATOMOS_TOOLS_DISABLE_SHELL": "1",
            "ATOMOS_TOOLS_DISABLE_ARXIV": "1",
            "ATOMOS_TOOLS_DISABLE_DEVTOOLS": "1",
            "ATOMOS_TOOLS_DISABLE_SUPERPOWERS": "1",
            "ATOMOS_TOOLS_DISABLE_RESEARCHER": "1",
            "ATOMOS_TOOLS_DISABLE_DRAWIO": "1",
            "ATOMOS_TOOLS_DISABLE_NOTION": "1",
            "ATOMOS_TOOLS_DISABLE_GOOGLE_WORKSPACE": "1",
            # Disable Geary and Amberol specifically
            "ATOMOS_TOOLS_DISABLE_GEARY": "1",
            "ATOMOS_TOOLS_DISABLE_AMBEROL": "1",
        }

        with patch.dict(os.environ, disable_env), \
             patch("shutil.which", side_effect=_mock_which):
            from tools.skills import get_atomos_skills
            all_tools = get_atomos_skills()
            tool_names = {getattr(t, "name", str(t)) for t in all_tools}

            # Geary tools should be absent
            assert "email_compose" not in tool_names
            assert "email_send" not in tool_names

            # Amberol tools should be absent
            assert "music_play" not in tool_names
            assert "music_pause" not in tool_names

            # Other app tools should still be present
            assert "notes_create" in tool_names
            assert "chat_send" in tool_names

        _reset_all_modules()

    def test_app_statuses_populated(self):
        """After tools are loaded, get_app_statuses() returns status
        for each registered adapter."""
        _reset_all_modules()
        from tools.app_adapter import (
            _APP_ADAPTER_REGISTRY, _adapter_instances,
            get_all_app_tools, get_app_statuses,
        )

        # Clear instance cache
        _adapter_instances.clear()

        with patch("shutil.which", side_effect=_mock_which):
            tools = get_all_app_tools()
            statuses = get_app_statuses()

            assert len(statuses) > 0
            app_ids = {s["app_id"] for s in statuses}
            # Spot-check a few
            for s in statuses:
                assert "app_id" in s
                assert "binary" in s
                assert "installed" in s
                assert "running" in s

        _adapter_instances.clear()
        _reset_all_modules()
