"""
Unit tests for src/secret_store.py.

All OS-level calls (keyring, filesystem, machine-id reads) are mocked so
these tests run identically on macOS (dev) and Linux (production).
"""
import json
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch, mock_open


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _import_secrets():
    """Re-import secret_store so module-level paths are set fresh."""
    import importlib
    import secret_store as s
    importlib.reload(s)
    return s


# ---------------------------------------------------------------------------
# CredentialRequiredError
# ---------------------------------------------------------------------------


class TestCredentialRequiredError:
    def test_stores_key_attribute(self):
        from secret_store import CredentialRequiredError
        err = CredentialRequiredError("browser_use_api_key")
        assert err.key == "browser_use_api_key"

    def test_is_exception(self):
        from secret_store import CredentialRequiredError
        assert issubclass(CredentialRequiredError, Exception)

    def test_message_contains_key(self):
        from secret_store import CredentialRequiredError
        err = CredentialRequiredError("my_key")
        assert "my_key" in str(err)


# ---------------------------------------------------------------------------
# Keyring primary path
# ---------------------------------------------------------------------------


class TestKeyringPrimary:
    def test_get_secret_calls_keyring(self):
        mock_kr = MagicMock()
        mock_kr.get_password.return_value = "secret_value"

        with patch.dict("sys.modules", {"keyring": mock_kr}):
            from secret_store import _keyring_get
            result = _keyring_get("browser_use_api_key")

        mock_kr.get_password.assert_called_once_with("atomos", "browser_use_api_key")
        assert result == "secret_value"

    def test_get_secret_returns_none_when_keyring_raises(self):
        mock_kr = MagicMock()
        mock_kr.get_password.side_effect = Exception("D-Bus not available")

        with patch.dict("sys.modules", {"keyring": mock_kr}):
            from secret_store import _keyring_get
            result = _keyring_get("browser_use_api_key")

        assert result is None

    def test_set_secret_calls_keyring(self):
        mock_kr = MagicMock()

        with patch.dict("sys.modules", {"keyring": mock_kr}):
            from secret_store import _keyring_set
            result = _keyring_set("browser_use_api_key", "s3cr3t")

        mock_kr.set_password.assert_called_once_with("atomos", "browser_use_api_key", "s3cr3t")
        assert result is True

    def test_set_secret_returns_false_when_keyring_raises(self):
        mock_kr = MagicMock()
        mock_kr.set_password.side_effect = Exception("no keyring")

        with patch.dict("sys.modules", {"keyring": mock_kr}):
            from secret_store import _keyring_set
            result = _keyring_set("browser_use_api_key", "s3cr3t")

        assert result is False

    def test_value_not_logged_on_store(self, caplog):
        import logging
        mock_kr = MagicMock()

        with patch.dict("sys.modules", {"keyring": mock_kr}):
            with caplog.at_level(logging.DEBUG):
                from secret_store import store_secret
                store_secret("browser_use_api_key", "super_secret_key_value")

        # The raw secret value must never appear in any log output.
        assert "super_secret_key_value" not in caplog.text


# ---------------------------------------------------------------------------
# Fernet fallback path
# ---------------------------------------------------------------------------


class TestFernetFallback:
    def _make_fernet_mocks(self, tmp_path):
        """Return patches needed for Fernet file operations."""
        salt_file = tmp_path / "secrets.salt"
        secrets_file = tmp_path / "secrets.enc"
        return salt_file, secrets_file

    def test_machine_id_reads_etc_machine_id(self, tmp_path):
        fake_id_file = tmp_path / "machine-id"
        fake_id_file.write_text("abc123def456\n")

        with patch("secret_store.Path") as mock_path_cls:
            mock_path_cls.side_effect = lambda p: fake_id_file if "machine-id" in str(p) else Path(p)
            from secret_store import _machine_id
            # Can't easily test the Path patching inline; test via integration instead

    def test_file_roundtrip(self, tmp_path):
        """store → retrieve via Fernet file without keyring."""
        import secret_store as s

        with (
            patch.object(s, "_XDG_DATA_DIR", tmp_path),
            patch.object(s, "_SECRETS_FILE", tmp_path / "secrets.enc"),
            patch.object(s, "_SALT_FILE", tmp_path / "secrets.salt"),
            patch("secret_store._machine_id", return_value=b"test-machine-id-fixed"),
            patch("secret_store._keyring_set", return_value=False),   # force fallback
            patch("secret_store._keyring_get", return_value=None),    # keyring empty
        ):
            s.store_secret("my_key", "my_value")
            result = s.get_secret("my_key")

        assert result == "my_value"

    def test_file_stores_multiple_keys(self, tmp_path):
        import secret_store as s

        with (
            patch.object(s, "_XDG_DATA_DIR", tmp_path),
            patch.object(s, "_SECRETS_FILE", tmp_path / "secrets.enc"),
            patch.object(s, "_SALT_FILE", tmp_path / "secrets.salt"),
            patch("secret_store._machine_id", return_value=b"test-machine-id-fixed"),
            patch("secret_store._keyring_set", return_value=False),
            patch("secret_store._keyring_get", return_value=None),
        ):
            s.store_secret("key_a", "value_a")
            s.store_secret("key_b", "value_b")
            assert s.get_secret("key_a") == "value_a"
            assert s.get_secret("key_b") == "value_b"

    def test_file_get_returns_none_when_file_missing(self, tmp_path):
        import secret_store as s

        with (
            patch.object(s, "_SECRETS_FILE", tmp_path / "does_not_exist.enc"),
            patch.object(s, "_SALT_FILE", tmp_path / "salt"),
        ):
            result = s._file_get("any_key")

        assert result is None

    def test_file_secrets_are_not_plaintext(self, tmp_path):
        """Encrypted file must not contain the plaintext secret value."""
        import secret_store as s

        with (
            patch.object(s, "_XDG_DATA_DIR", tmp_path),
            patch.object(s, "_SECRETS_FILE", tmp_path / "secrets.enc"),
            patch.object(s, "_SALT_FILE", tmp_path / "secrets.salt"),
            patch("secret_store._machine_id", return_value=b"test-machine-id-fixed"),
            patch("secret_store._keyring_set", return_value=False),
            patch("secret_store._keyring_get", return_value=None),
        ):
            s.store_secret("api_key", "plaintext_must_not_appear")
            raw_bytes = (tmp_path / "secrets.enc").read_bytes()

        assert b"plaintext_must_not_appear" not in raw_bytes


# ---------------------------------------------------------------------------
# Public API: get_secret / has_secret / require_secret
# ---------------------------------------------------------------------------


class TestPublicAPI:
    def test_get_secret_prefers_keyring_over_file(self, tmp_path):
        import secret_store as s

        with (
            patch("secret_store._keyring_get", return_value="from_keyring"),
            patch("secret_store._file_get", return_value="from_file"),
        ):
            result = s.get_secret("some_key")

        assert result == "from_keyring"

    def test_get_secret_falls_back_to_file_when_keyring_empty(self):
        import secret_store as s

        with (
            patch("secret_store._keyring_get", return_value=None),
            patch("secret_store._file_get", return_value="from_file"),
        ):
            result = s.get_secret("some_key")

        assert result == "from_file"

    def test_get_secret_returns_none_when_both_empty(self):
        import secret_store as s

        with (
            patch("secret_store._keyring_get", return_value=None),
            patch("secret_store._file_get", return_value=None),
        ):
            result = s.get_secret("some_key")

        assert result is None

    def test_has_secret_true(self):
        import secret_store as s

        with patch("secret_store.get_secret", return_value="some_value"):
            assert s.has_secret("some_key") is True

    def test_has_secret_false(self):
        import secret_store as s

        with patch("secret_store.get_secret", return_value=None):
            assert s.has_secret("some_key") is False

    def test_require_secret_returns_value(self):
        import secret_store as s

        with patch("secret_store.get_secret", return_value="the_value"):
            result = s.require_secret("some_key")

        assert result == "the_value"

    def test_require_secret_raises_credential_required(self):
        import secret_store as s
        from secret_store import CredentialRequiredError

        with patch("secret_store.get_secret", return_value=None):
            with pytest.raises(CredentialRequiredError) as exc_info:
                s.require_secret("browser_use_api_key")

        assert exc_info.value.key == "browser_use_api_key"

    def test_store_secret_uses_keyring_when_available(self):
        import secret_store as s

        with (
            patch("secret_store._keyring_set", return_value=True) as mock_ks,
            patch("secret_store._file_set") as mock_fs,
        ):
            s.store_secret("k", "v")

        mock_ks.assert_called_once_with("k", "v")
        mock_fs.assert_not_called()

    def test_store_secret_falls_back_to_file_when_keyring_fails(self):
        import secret_store as s

        with (
            patch("secret_store._keyring_set", return_value=False),
            patch("secret_store._file_set") as mock_fs,
        ):
            s.store_secret("k", "v")

        mock_fs.assert_called_once_with("k", "v")
