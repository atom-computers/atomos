"""
LangChain tool for launching a GUI code editor.

code_editor — launch a file/directory in Zed (or best available editor)
"""

import logging
import os
import platform
import shutil
import subprocess
from pathlib import Path
from typing import Any, List

from langchain_core.tools import tool

logger = logging.getLogger(__name__)

_EDITOR_CANDIDATES = ["zed", "code", "codium"]

_EXTRA_EDITOR_PATHS = [
    "/opt/zed.app/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/snap/bin",
]


def _resolve_home() -> Path:
    """Best-effort resolution of the real user's home directory.

    When the agent service runs as root via systemd, $HOME is /root.
    Fall back to $SUDO_USER's home, then the first real user in /home.
    """
    home = Path.home()
    if home != Path("/root"):
        return home
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        candidate = Path("/home") / sudo_user
        if candidate.is_dir():
            return candidate
    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir() and not entry.name.startswith("."):
                return entry
    except OSError:
        pass
    return home


def _resolve_user() -> str | None:
    """Return the login name of the real desktop user, or None."""
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        return sudo_user
    home = _resolve_home()
    if home != Path.home() and home.parent == Path("/home"):
        return home.name
    import getpass
    name = getpass.getuser()
    return None if name == "root" else name


def _resolve_path(raw: str) -> Path:
    """Sanitize and resolve a path from the LLM.

    - Tilde (``~``) is expanded to the real user's home.
    - Absolute paths are used as-is.
    - Relative paths are anchored to the user's home directory (NOT the
      service CWD, which is ``/opt/atomos/agents/src/``).
    - Concatenated double-paths are cleaned up (keeps the last absolute).
    """
    cleaned = raw.strip()
    parts = cleaned.split()
    for part in reversed(parts):
        if part.startswith("/") or part.startswith("~"):
            cleaned = part
            break

    p = Path(cleaned)
    if cleaned.startswith("~"):
        p = Path(str(p).replace("~", str(_resolve_home()), 1))
    elif not p.is_absolute():
        p = _resolve_home() / p

    return p.resolve()


def _find_editor() -> str | None:
    """Return the absolute path to the first available GUI editor.

    Priority order: zed > code > codium.  Checks:
    1. ``shutil.which`` (whatever is in PATH)
    2. The real user's ``~/.local/bin``
    3. Common system paths
    4. Scan ``/opt/*/bin/`` for Zed (the tarball extracts to varying names)
    """
    user_home = _resolve_home()
    search_dirs = [
        user_home / ".local" / "bin",
        *(Path(p) for p in _EXTRA_EDITOR_PATHS),
    ]

    for name in _EDITOR_CANDIDATES:
        found = shutil.which(name)
        if found:
            logger.info("Editor found via PATH: %s → %s", name, found)
            return found

        for d in search_dirs:
            candidate = d / name
            if candidate.is_file() and os.access(candidate, os.X_OK):
                logger.info("Editor found at: %s", candidate)
                return str(candidate)

    # Zed tarball extracts to varying directory names under /opt
    # (zed.app, zed-linux-x86_64, zed-preview, etc.)
    opt = Path("/opt")
    if opt.is_dir():
        for entry in sorted(opt.iterdir()):
            candidate = entry / "bin" / "zed"
            if candidate.is_file() and os.access(candidate, os.X_OK):
                logger.info("Editor found via /opt scan: %s", candidate)
                return str(candidate)

    logger.warning("No editor found (tried %s in PATH + %s + /opt/*/bin/)",
                    _EDITOR_CANDIDATES, [str(d) for d in search_dirs])
    return None


def _build_gui_env() -> dict[str, str]:
    """Build an environment dict suitable for launching a GUI app.

    Copies the current env and ensures Wayland/X11 display variables are
    present (same probing strategy as browser_local.py).  Also sets HOME
    to the real user's home so the editor finds its config.
    """
    env = os.environ.copy()
    env["HOME"] = str(_resolve_home())

    if not env.get("WAYLAND_DISPLAY") and not env.get("DISPLAY"):
        import glob as _glob
        run_user = "/run/user"
        if os.path.isdir(run_user):
            for uid_dir in sorted(os.listdir(run_user)):
                xdg = os.path.join(run_user, uid_dir)
                sockets = _glob.glob(os.path.join(xdg, "wayland-*"))
                sockets = [s for s in sockets
                           if not s.endswith(".lock") and os.path.exists(s)]
                if sockets:
                    sockets.sort()
                    env["WAYLAND_DISPLAY"] = os.path.basename(sockets[0])
                    env.setdefault("XDG_RUNTIME_DIR", xdg)
                    logger.info("Probed Wayland: WAYLAND_DISPLAY=%s XDG_RUNTIME_DIR=%s",
                                env["WAYLAND_DISPLAY"], xdg)
                    break

    return env


def _launch_gui(cmd: list[str]) -> bool:
    """Launch a GUI command as the real desktop user.

    When running as root, uses ``runuser -u <user>`` so the process
    belongs to the desktop session.  Falls back to a direct launch
    with the display env injected.
    """
    env = _build_gui_env()
    user = _resolve_user()

    try:
        if user and os.getuid() == 0:
            subprocess.Popen(
                ["runuser", "-u", user, "--"] + cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
        else:
            subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
        return True
    except (FileNotFoundError, OSError) as exc:
        logger.warning("GUI launch failed for %s: %s", cmd, exc)
        return False


@tool("code_editor")
def open_in_editor(path: str) -> str:
    """Open a file, project folder, or coding workspace in the code editor (Zed).

    Use this whenever the user wants to write code, start a coding project,
    view source files, or work in a development environment.  Opening a
    directory gives the user a full project workspace with a file tree,
    syntax highlighting, and integrated terminal.

    Args:
        path: Absolute path to a file or project directory to open.
              For coding tasks, pass the project root directory.

    Returns:
        Confirmation message or error description
    """
    resolved = _resolve_path(path)
    if not resolved.exists():
        return f"$ open {resolved}\n[error: path does not exist]"

    editor = _find_editor()
    if editor:
        name = os.path.basename(editor)
        if _launch_gui([editor, str(resolved)]):
            return f"$ {name} {resolved}"
        logger.warning("Editor %s failed — trying OS default", editor)

    system = platform.system()
    fallback = "xdg-open" if system == "Linux" else ("open" if system == "Darwin" else None)
    if fallback and _launch_gui([fallback, str(resolved)]):
        return f"$ {fallback} {resolved}"

    return (
        f"$ open {resolved}\n"
        f"[error: no editor found (tried {', '.join(_EDITOR_CANDIDATES)})]"
    )


def get_editor_tools() -> List[Any]:
    """Return editor-facing tools only."""
    return [open_in_editor]
