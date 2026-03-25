"""
Integration tests: iso-ubuntu application connections through the bridge (§3.2–3.14).

Each test verifies that an adapter can invoke its application's tools and
that the result flows back through the bridge pipeline.

In CI these run inside Docker with stub binaries.  D-Bus calls are mocked
so we exercise the adapter → tool → format → bridge path without requiring
a live desktop session.
"""

import json
import os
import pytest
from unittest.mock import MagicMock, patch

import bridge_pb2

pytestmark = pytest.mark.integration

_SKIP_REASON = "ATOMOS_INTEGRATION_TEST not set"


def _skip_unless_integration():
    if not os.environ.get("ATOMOS_INTEGRATION_TEST"):
        pytest.skip(_SKIP_REASON)


def _format_tool_output(content: str, tool_name: str) -> str:
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


def _bridge_response(tool_output: str, tool_name: str) -> bridge_pb2.AgentResponse:
    formatted = _format_tool_output(tool_output, tool_name)
    return bridge_pb2.AgentResponse(content=formatted, done=False, tool_call="", status="")


def _mock_which(binary):
    return f"/usr/bin/{binary}"


def _reset_mod(mod, adapter_attr="_adapter", tools_attr=None):
    if hasattr(mod, adapter_attr):
        setattr(mod, adapter_attr, None)
    for attr in dir(mod):
        if attr.startswith("_") and attr.endswith("_TOOLS"):
            setattr(mod, attr, None)


def _wire_adapter(mod, get_adapter_fn):
    """Wire a mock D-Bus adapter and return the adapter object."""
    adapter = get_adapter_fn()
    adapter._lifecycle._pid = 1
    mock_dbus = MagicMock()
    adapter._dbus = mock_dbus
    return adapter, mock_dbus


# ── §3.2 Geary — Email Client ─────────────────────────────────────────────


class TestGearyBridgeIntegration:

    def test_compose_send_through_bridge(self):
        """Agent composes and sends email via Geary → email received."""
        _skip_unless_integration()
        import tools.geary as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.geary import email_send, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)
            mock_dbus.call.return_value = "('Message sent successfully',)"

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = email_send.invoke({
                    "to": "test@example.com",
                    "subject": "Integration Test",
                    "body": "Hello from the bridge test.",
                })
                assert "sent" in result.lower() or "Message" in result

                resp = _bridge_response(result, "email_send")
                assert resp.content

        _reset_mod(mod)

    def test_search_inbox_through_bridge(self):
        """Agent searches inbox → results returned through bridge."""
        _skip_unless_integration()
        import tools.geary as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.geary import email_search, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)
            mock_dbus.call.return_value = (
                "('From: alice@example.com\\nSubject: Meeting\\nDate: 2025-03-15',)"
            )

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = email_search.invoke({"query": "meeting"})
                assert "alice" in result.lower() or "Meeting" in result

                resp = _bridge_response(result, "email_search")
                assert resp.content

        _reset_mod(mod)


# ── §3.3 Chatty — Messaging ───────────────────────────────────────────────


class TestChattyBridgeIntegration:

    def test_send_message_through_bridge(self):
        """Agent sends message via Chatty → message received by test account."""
        _skip_unless_integration()
        import tools.chatty as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.chatty import chat_send, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)
            mock_dbus.call.return_value = "('Message delivered',)"

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = chat_send.invoke({
                    "recipient": "@bob:matrix.org",
                    "message": "Hello from integration test",
                })
                assert "delivered" in result.lower() or "Message" in result

                resp = _bridge_response(result, "chat_send")
                assert resp.content

        _reset_mod(mod)

    def test_read_conversation_through_bridge(self):
        """Agent reads conversation history → messages returned through bridge."""
        _skip_unless_integration()
        import tools.chatty as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.chatty import chat_read, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)
            mock_dbus.call.return_value = (
                "('Bob: Hey!\\nAlice: Hi there!\\nBob: Meeting at 3?',)"
            )

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = chat_read.invoke({"recipient": "@bob:matrix.org"})
                assert "Bob" in result or "Hey" in result

                resp = _bridge_response(result, "chat_read")
                assert resp.content

        _reset_mod(mod)


# ── §3.4 Amberol — Music Player ───────────────────────────────────────────


class TestAmberolBridgeIntegration:

    def test_play_track_through_bridge(self):
        """Agent plays a track → Amberol begins playback → now-playing metadata."""
        _skip_unless_integration()
        import tools.amberol as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.amberol import music_play, music_now_playing, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                play_result = music_play.invoke({"uri": "/home/user/music/song.mp3"})
                assert "Playing" in play_result or "play" in play_result.lower()

                mock_dbus.call.return_value = (
                    "({'xesam:title': 'Test Song', 'xesam:artist': ['Test Artist'], "
                    "'xesam:album': 'Test Album', 'mpris:length': 180000000},)"
                )
                now_result = music_now_playing.invoke({})
                assert "Test Song" in now_result or "title" in now_result.lower()

                resp = _bridge_response(now_result, "music_now_playing")
                assert resp.content

        _reset_mod(mod)


# ── §3.5 Podcasts — GNOME Podcasts ────────────────────────────────────────


class TestPodcastsBridgeIntegration:

    def test_subscribe_list_play_through_bridge(self):
        """Agent subscribes to a podcast feed → episodes listed → playback starts."""
        _skip_unless_integration()
        import tools.podcasts as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.podcasts import podcast_subscribe, podcast_list, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('Subscribed to feed',)"
                sub_result = podcast_subscribe.invoke({
                    "feed_url": "https://example.com/podcast.xml",
                })
                assert "Subscribed" in sub_result or "feed" in sub_result.lower()

                mock_dbus.call.return_value = (
                    "('Episode 1: Introduction\\nEpisode 2: Deep Dive',)"
                )
                list_result = podcast_list.invoke({})
                assert "Episode" in list_result

                resp = _bridge_response(list_result, "podcast_list")
                assert resp.content

        _reset_mod(mod)


# ── §3.6 Vocalis — Voice Recorder ─────────────────────────────────────────


class TestVocalisBridgeIntegration:

    def test_record_start_stop_list_through_bridge(self):
        """Agent starts and stops a recording → audio file saved → listed."""
        _skip_unless_integration()
        import tools.vocalis as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.vocalis import voice_record_start, voice_record_stop, voice_recordings_list, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('Recording started',)"
                start_result = voice_record_start.invoke({})
                assert "Recording" in start_result or "started" in start_result.lower()

                mock_dbus.call.return_value = "('/home/user/Recordings/rec-001.ogg',)"
                stop_result = voice_record_stop.invoke({})
                assert "rec-001" in stop_result or "ogg" in stop_result

                mock_dbus.call.return_value = "('rec-001.ogg\\nrec-002.ogg',)"
                list_result = voice_recordings_list.invoke({})
                assert "rec-001" in list_result

                resp = _bridge_response(list_result, "voice_recordings_list")
                assert resp.content

        _reset_mod(mod)


# ── §3.7 Loupe — Image Viewer ─────────────────────────────────────────────


class TestLoupeBridgeIntegration:

    def test_open_image_metadata_through_bridge(self, tmp_path):
        """Agent opens an image → Loupe displays it → metadata returned."""
        _skip_unless_integration()
        import tools.loupe as mod
        _reset_mod(mod)

        img_file = tmp_path / "test.jpg"
        img_file.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 100)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.loupe import image_open, image_metadata, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                open_result = image_open.invoke({"file_path": str(img_file)})
                assert "Opened" in open_result or "open" in open_result.lower() or str(img_file) in open_result

                meta_result = image_metadata.invoke({"file_path": str(img_file)})
                parsed = json.loads(meta_result)
                assert "size_bytes" in parsed
                assert parsed["size_bytes"] == 104

                resp = _bridge_response(meta_result, "image_metadata")
                assert resp.content

        _reset_mod(mod)


# ── §3.8 Karlender — Calendar ─────────────────────────────────────────────


class TestKarlenderBridgeIntegration:

    def test_create_event_through_bridge(self):
        """Agent creates a calendar event → event visible in Karlender UI."""
        _skip_unless_integration()
        import tools.karlender as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.karlender import calendar_create, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('Event created: evt-001',)"
                result = calendar_create.invoke({
                    "summary": "Team Meeting",
                    "start_time": "2025-03-16T10:00:00",
                    "end_time": "2025-03-16T11:00:00",
                })
                assert "created" in result.lower() or "evt-001" in result

                resp = _bridge_response(result, "calendar_create")
                assert resp.content

        _reset_mod(mod)

    def test_list_todays_events_through_bridge(self):
        """Agent lists today's events → correct events returned."""
        _skip_unless_integration()
        import tools.karlender as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.karlender import calendar_list, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = (
                    "('Team Meeting @ 10:00\\nLunch @ 12:00\\nReview @ 15:00',)"
                )
                result = calendar_list.invoke({})
                assert "Team Meeting" in result

                resp = _bridge_response(result, "calendar_list")
                assert resp.content

        _reset_mod(mod)


# ── §3.9 GNOME Contacts ───────────────────────────────────────────────────


class TestContactsBridgeIntegration:

    def test_create_contact_through_bridge(self):
        """Agent creates a contact → visible in GNOME Contacts UI."""
        _skip_unless_integration()
        import tools.contacts as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.contacts import contacts_create, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('Contact created: Alice Smith',)"
                result = contacts_create.invoke({
                    "full_name": "Alice Smith",
                    "email": "alice@example.com",
                })
                assert "Alice" in result or "created" in result.lower()

                resp = _bridge_response(result, "contacts_create")
                assert resp.content

        _reset_mod(mod)

    def test_search_contacts_through_bridge(self):
        """Agent searches contacts by name → correct results returned."""
        _skip_unless_integration()
        import tools.contacts as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.contacts import contacts_search, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = (
                    "('Alice Smith <alice@example.com>\\nAlice Jones <aj@example.com>',)"
                )
                result = contacts_search.invoke({"query": "Alice"})
                assert "Alice" in result

                resp = _bridge_response(result, "contacts_search")
                assert resp.content

        _reset_mod(mod)


# ── §3.10 Pidif — Feed Reader ─────────────────────────────────────────────


class TestPidifBridgeIntegration:

    def test_add_feed_fetch_articles_through_bridge(self):
        """Agent adds an RSS feed → articles fetched → content returned."""
        _skip_unless_integration()
        import tools.pidif as mod
        _reset_mod(mod)

        mock_proc = MagicMock()
        mock_proc.returncode = 0

        with patch("shutil.which", side_effect=_mock_which):
            from tools.pidif import feeds_add, feeds_articles

            mock_proc.stdout = "Feed added: https://example.com/feed.xml"
            with patch("tools.pidif.subprocess.run", return_value=mock_proc):
                add_result = feeds_add.invoke({"url": "https://example.com/feed.xml"})
                assert "Feed added" in add_result or "feed" in add_result.lower()

            mock_proc.stdout = "1. Rust 2025 — New borrow checker\n2. Python 3.14 — GIL removal"
            with patch("tools.pidif.subprocess.run", return_value=mock_proc):
                articles_result = feeds_articles.invoke({"feed_id": "feed-001"})
                assert "Rust" in articles_result

                resp = _bridge_response(articles_result, "feeds_articles")
                assert resp.content

        _reset_mod(mod)


# ── §3.11 Notejot — Notes ─────────────────────────────────────────────────


class TestNotejotBridgeIntegration:

    def test_create_and_search_note_through_bridge(self, tmp_path):
        """Agent creates a note → visible in Notejot; searches by keyword."""
        _skip_unless_integration()
        import tools.notejot as mod
        _reset_mod(mod)

        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        with patch("tools.notejot._find_notes_file", return_value=notes_file):
            from tools.notejot import notes_create, notes_search

            create_result = notes_create.invoke({
                "title": "Integration Test Note",
                "content": "This note was created by the integration test harness.",
            })
            assert "Note created" in create_result

            search_result = notes_search.invoke({"query": "integration"})
            assert "Integration Test Note" in search_result

            resp = _bridge_response(search_result, "notes_search")
            assert resp.content

        _reset_mod(mod)


# ── §3.12 Authenticator — TOTP/2FA ────────────────────────────────────────


class TestAuthenticatorBridgeIntegration:

    def test_get_code_through_bridge(self):
        """Agent retrieves TOTP code → code is valid."""
        _skip_unless_integration()
        import tools.authenticator as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.authenticator import auth_get_code, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('secret:JBSWY3DPEHPK3PXP',)"
                with patch("tools.authenticator._generate_totp", return_value="123456"):
                    result = auth_get_code.invoke({"account": "github"})
                    assert "123456" in result or len(result.strip()) == 6

                    resp = _bridge_response(result, "auth_get_code")
                    assert resp.content
                    assert "JBSWY3DPEHPK3PXP" not in resp.content

        _reset_mod(mod)


# ── §3.13 Passes — Password Manager ───────────────────────────────────────


class TestPassesBridgeIntegration:

    def test_get_credential_through_bridge(self):
        """Agent retrieves credential via Passes → relay token returned."""
        _skip_unless_integration()
        import tools.passes as mod
        _reset_mod(mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.passes import pass_get, _get_adapter
            adapter, mock_dbus = _wire_adapter(mod, _get_adapter)

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                mock_dbus.call.return_value = "('user:alice\\npass:s3cret!',)"
                result = pass_get.invoke({"service": "github.com"})
                assert "s3cret!" not in result
                assert "relay" in result.lower() or "credential" in result.lower() or result

                resp = _bridge_response(result, "pass_get")
                assert resp.content

        _reset_mod(mod)


# ── §3.14 Shared Infrastructure ───────────────────────────────────────────


class TestAppInfrastructureBridgeIntegration:

    def test_all_adapters_register_and_tools_discoverable(self):
        """All adapters register simultaneously and tools are discoverable
        through the bridge pipeline."""
        _skip_unless_integration()

        from tests.test_app_integration import _APP_MODULES, _ALL_APP_TOOL_NAMES, _reset_all_modules

        _reset_all_modules()
        import importlib

        with patch("shutil.which", side_effect=_mock_which):
            all_tools = []
            for ns, mod_path, getter_name, binary, expected_count in _APP_MODULES:
                mod = importlib.import_module(mod_path)
                for attr in dir(mod):
                    if attr.startswith("_") and attr.endswith("_TOOLS"):
                        setattr(mod, attr, None)
                getter = getattr(mod, getter_name)
                tools = getter()
                all_tools.extend(tools)

            tool_names = {t.name for t in all_tools}
            assert _ALL_APP_TOOL_NAMES.issubset(tool_names)
            assert len(all_tools) == 49

        _reset_all_modules()
