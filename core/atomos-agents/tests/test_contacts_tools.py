"""
Tests for the GNOME Contacts adapter (tools/contacts.py).

Covers:
  - Tool registration and discovery via get_contacts_tools()
  - Tool names and argument schemas
  - EDS D-Bus integration (mock)
  - vCard generation
  - Error handling
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.contacts as mod
    mod._adapter = None
    mod._CONTACTS_TOOLS = None


class TestContactsToolRegistration:

    def test_get_contacts_tools_returns_four(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/gnome-contacts"):
            from tools.contacts import get_contacts_tools
            result = get_contacts_tools()
            assert len(result) == 4
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/gnome-contacts"):
            from tools.contacts import get_contacts_tools
            names = {t.name for t in get_contacts_tools()}
            assert names == {"contacts_list", "contacts_search", "contacts_create", "contacts_get"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.contacts import get_contacts_tools
            result = get_contacts_tools()
            assert result == []
        _reset()


class TestContactsList:

    def test_list_returns_contacts(self):
        _reset()
        from tools.contacts import contacts_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Alice Smith <alice@test.com>', 'Bob Jones <bob@test.com>')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_list.invoke({"limit": 50})
            assert "Alice Smith" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.contacts import contacts_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_list.invoke({"limit": 50})
            assert "no contacts found" in result
        _reset()

    def test_list_dbus_error_cli_fallback(self):
        _reset()
        from tools.contacts import contacts_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Alice Smith\nBob Jones"

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.run", return_value=mock_proc):
            result = contacts_list.invoke({"limit": 50})
            assert "Alice Smith" in result
        _reset()

    def test_list_all_fallbacks_fail(self):
        _reset()
        from tools.contacts import contacts_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("subprocess.run", side_effect=FileNotFoundError("nope")):
            result = contacts_list.invoke({"limit": 50})
            assert "unavailable" in result
        _reset()


class TestContactsSearch:

    def test_search_returns_matches(self):
        _reset()
        from tools.contacts import contacts_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Alice Smith <alice@test.com>',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_search.invoke({"query": "Alice"})
            assert "Alice" in result
        _reset()

    def test_search_no_results(self):
        _reset()
        from tools.contacts import contacts_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_search.invoke({"query": "Zaphod"})
            assert "no contacts matching" in result
        _reset()

    def test_search_dbus_error(self):
        _reset()
        from tools.contacts import contacts_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_search.invoke({"query": "test"})
            assert "unavailable" in result
        _reset()


class TestContactsCreate:

    def test_create_contact(self):
        _reset()
        from tools.contacts import contacts_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_create.invoke({
                "full_name": "Alice Smith",
                "email": "alice@test.com",
                "phone": "+1555123456",
            })
            assert "Contact created" in result
            assert "Alice Smith" in result

            call_args = mock_dbus.call.call_args
            vcard_arg = call_args[0][-1]
            assert "BEGIN:VCARD" in vcard_arg
            assert "FN:Alice Smith" in vcard_arg
            assert "alice@test.com" in vcard_arg
        _reset()

    def test_create_minimal_contact(self):
        _reset()
        from tools.contacts import contacts_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_create.invoke({"full_name": "Bob"})
            assert "Contact created" in result
            assert "Bob" in result
        _reset()

    def test_create_dbus_error(self):
        _reset()
        from tools.contacts import contacts_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_create.invoke({
                "full_name": "Alice Smith",
                "email": "alice@test.com",
            })
            assert "Failed" in result
        _reset()


class TestContactsGet:

    def test_get_contact_by_id(self):
        _reset()
        from tools.contacts import contacts_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "BEGIN:VCARD\nVERSION:3.0\nFN:Alice Smith\nEND:VCARD"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_get.invoke({"contact_id": "contact-42"})
            assert "Alice Smith" in result
        _reset()

    def test_get_contact_not_found(self):
        _reset()
        from tools.contacts import contacts_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_get.invoke({"contact_id": "missing-99"})
            assert "not found" in result
        _reset()

    def test_get_contact_dbus_error(self):
        _reset()
        from tools.contacts import contacts_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = contacts_get.invoke({"contact_id": "contact-42"})
            assert "unavailable" in result
        _reset()


class TestVCardGeneration:

    def test_build_vcard_full(self):
        _reset()
        from tools.contacts import _build_vcard
        vcard = _build_vcard(
            full_name="Alice Smith",
            email="alice@test.com",
            phone="+1555123456",
            address="123 Main St",
            organization="ACME Inc",
            note="Test contact",
        )
        assert "BEGIN:VCARD" in vcard
        assert "VERSION:3.0" in vcard
        assert "FN:Alice Smith" in vcard
        assert "N:Smith;Alice;;;" in vcard
        assert "EMAIL;TYPE=INTERNET:alice@test.com" in vcard
        assert "TEL;TYPE=CELL:+1555123456" in vcard
        assert "ORG:ACME Inc" in vcard
        assert "NOTE:Test contact" in vcard
        assert "END:VCARD" in vcard
        _reset()

    def test_build_vcard_minimal(self):
        _reset()
        from tools.contacts import _build_vcard
        vcard = _build_vcard(full_name="Bob")
        assert "FN:Bob" in vcard
        assert "N:;Bob;;;" in vcard
        assert "EMAIL" not in vcard
        assert "TEL" not in vcard
        _reset()


class TestRegistryIntegration:

    def test_contacts_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "contacts_list" in _ALLOWED_EXPOSED_TOOLS
        assert "contacts_search" in _ALLOWED_EXPOSED_TOOLS
        assert "contacts_create" in _ALLOWED_EXPOSED_TOOLS
        assert "contacts_get" in _ALLOWED_EXPOSED_TOOLS
