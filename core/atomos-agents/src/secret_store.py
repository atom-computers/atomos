"""
Secure credential storage for AtomOS agents.

Primary backend: gnome-keyring via the Freedesktop Secret Service API (D-Bus).
Fallback backend: Fernet-encrypted file at $XDG_DATA_HOME/atomos/secrets.enc,
  keyed from /etc/machine-id so secrets are machine-bound without a password.

The API key value is never logged, never placed in LLM messages, and never
stored in environment variables. Tools retrieve it at call time via
require_secret(), using the service/key name as a sentinel in any display context.
"""

import json
import logging
import os
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

SERVICE_NAME = "atomos"

_XDG_DATA_DIR = (
    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "atomos"
)
_SECRETS_FILE = _XDG_DATA_DIR / "secrets.enc"
_SALT_FILE = _XDG_DATA_DIR / "secrets.salt"


class CredentialRequiredError(Exception):
    """Raised when a required credential is absent from all storage backends."""

    def __init__(self, key: str):
        self.key = key
        super().__init__(f"Credential required: {key}")


# ── Primary: gnome-keyring via Freedesktop Secret Service (D-Bus) ─────────────


def _keyring_get(key: str) -> Optional[str]:
    try:
        import keyring

        return keyring.get_password(SERVICE_NAME, key)
    except Exception as exc:
        logger.debug("keyring.get_password unavailable for key=%s: %s", key, exc)
        return None


def _keyring_set(key: str, value: str) -> bool:
    try:
        import keyring

        keyring.set_password(SERVICE_NAME, key, value)
        return True
    except Exception as exc:
        logger.debug("keyring.set_password failed for key=%s: %s", key, exc)
        return False


# ── Fallback: Fernet-encrypted file ───────────────────────────────────────────


def _machine_id() -> bytes:
    """Return a stable per-machine identifier for Fernet key derivation."""
    for candidate in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        p = Path(candidate)
        if p.exists():
            return p.read_text().strip().encode()
    import socket

    logger.warning("No /etc/machine-id found; using hostname for key derivation")
    return socket.gethostname().encode()


def _build_fernet(salt: bytes):
    import base64

    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.fernet import Fernet

    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        iterations=480_000,
    )
    key = base64.urlsafe_b64encode(kdf.derive(_machine_id()))
    return Fernet(key)


def _load_fernet():
    """Return a Fernet instance, creating salt + data dir on first use."""
    _XDG_DATA_DIR.mkdir(parents=True, exist_ok=True)

    if _SALT_FILE.exists():
        salt = _SALT_FILE.read_bytes()
    else:
        salt = os.urandom(16)
        _SALT_FILE.write_bytes(salt)
        _SALT_FILE.chmod(0o600)

    return _build_fernet(salt)


def _file_get(key: str) -> Optional[str]:
    try:
        if not _SECRETS_FILE.exists():
            return None
        f = _load_fernet()
        data: dict = json.loads(f.decrypt(_SECRETS_FILE.read_bytes()))
        return data.get(key)
    except Exception as exc:
        logger.debug("Encrypted file read failed for key=%s: %s", key, exc)
        return None


def _file_set(key: str, value: str) -> None:
    _XDG_DATA_DIR.mkdir(parents=True, exist_ok=True)
    f = _load_fernet()
    try:
        existing: dict = (
            json.loads(f.decrypt(_SECRETS_FILE.read_bytes()))
            if _SECRETS_FILE.exists()
            else {}
        )
    except Exception:
        existing = {}
    existing[key] = value
    _SECRETS_FILE.write_bytes(f.encrypt(json.dumps(existing).encode()))
    _SECRETS_FILE.chmod(0o600)


# ── Public API ─────────────────────────────────────────────────────────────────


def get_secret(key: str) -> Optional[str]:
    """Return a stored secret, checking gnome-keyring then encrypted file."""
    return _keyring_get(key) or _file_get(key)


def store_secret(key: str, value: str) -> None:
    """Persist a secret. Value is never logged or placed in agent context."""
    if not _keyring_set(key, value):
        logger.info("Keyring unavailable; falling back to encrypted file (key=%s)", key)
        _file_set(key, value)
    logger.info("Stored secret key=%s (value redacted)", key)


def has_secret(key: str) -> bool:
    return get_secret(key) is not None


def require_secret(key: str) -> str:
    """Return a secret or raise CredentialRequiredError if absent."""
    value = get_secret(key)
    if not value:
        raise CredentialRequiredError(key)
    return value
