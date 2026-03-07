"""
LangChain tools for code editing and Zed editor integration.

open_in_editor    — launch a file/directory in Zed (or best available editor)
read_file         — read file contents with optional line range
edit_file         — search-and-replace a text span in a file
create_file       — create a new file with given contents
search_in_files   — regex search across files via ripgrep

When the agent is invoked from the COSMIC applet (via gRPC), these tools
give it direct filesystem access and the ability to surface results in
Zed.  When the agent runs inside Zed over ACP, the editor provides its
own file context — but these tools remain available for out-of-band
filesystem operations.
"""

import logging
import os
import platform
import shutil
import subprocess
from pathlib import Path
from typing import Any, List, Optional

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


_opened_projects: set[str] = set()


def _project_root(path: Path) -> Path:
    """Return the project root directory for *path*.

    The project root is the first directory component below the user's
    home (e.g. ``/home/atom/my_project/src/main.py`` → ``/home/atom/my_project``).
    Falls back to the file's parent directory if it isn't under $HOME.
    """
    home = _resolve_home()
    try:
        rel = path.relative_to(home)
        if rel.parts:
            return home / rel.parts[0]
    except ValueError:
        pass
    return path.parent


def _auto_open_project(path: Path) -> str | None:
    """Open the project directory in the editor once per project.

    On the first file created under a project root, the whole directory
    is opened in Zed so the user sees the file tree.  Subsequent files
    under the same root are skipped — Zed already has the directory open
    and shows new files automatically.

    Returns the editor name on success, None otherwise.
    """
    project = _project_root(path)
    key = str(project)
    if key in _opened_projects:
        return None

    editor = _find_editor()
    if editor and _launch_gui([editor, str(project)]):
        _opened_projects.add(key)
        return os.path.basename(editor)
    return None


def _auto_open_file(path: Path) -> str | None:
    """Open an individual file in the editor (used after edits).

    If the project is already open in Zed, this focuses the specific
    file.  If not, it opens the file and Zed creates a new window.
    """
    editor = _find_editor()
    if editor and _launch_gui([editor, str(path)]):
        return os.path.basename(editor)
    return None


@tool
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


@tool
def read_file(
    file_path: str,
    offset: Optional[int] = None,
    limit: Optional[int] = None,
) -> str:
    """Read the contents of a file on disk.

    Returns numbered lines so edits can reference exact positions.

    Args:
        file_path: Path to the file to read
        offset: Optional 1-indexed line number to start from
        limit: Optional maximum number of lines to return

    Returns:
        Numbered file contents, or an error message
    """
    resolved = _resolve_path(file_path)
    if not resolved.is_file():
        return f"File not found: {resolved}"
    try:
        text = resolved.read_text(errors="replace")
        lines = text.splitlines()
        start = max((offset or 1) - 1, 0)
        end = (start + limit) if limit else len(lines)
        numbered = [
            f"{i + 1:>6}|{line}"
            for i, line in enumerate(lines[start:end], start=start)
        ]
        return "\n".join(numbered) if numbered else "(empty file)"
    except Exception as exc:
        return f"Error reading {resolved}: {exc}"


@tool
def edit_file(file_path: str, old_text: str, new_text: str) -> str:
    """Edit a file by replacing an exact text span with new text.

    The old_text must appear verbatim in the file (including whitespace
    and indentation).  Only the first occurrence is replaced.

    Args:
        file_path: Path to the file to edit
        old_text: Exact text to find and replace
        new_text: Replacement text

    Returns:
        Confirmation or error message
    """
    resolved = _resolve_path(file_path)
    if not resolved.is_file():
        return f"$ edit {resolved}\n[error: file not found]"
    try:
        content = resolved.read_text()
        if old_text not in content:
            return (
                f"$ edit {resolved}\n"
                "[error: old_text not found — ensure it matches exactly, including whitespace]"
            )
        updated = content.replace(old_text, new_text, 1)
        resolved.write_text(updated)
        editor = _auto_open_file(resolved)
        opened = f" → opened in {editor}" if editor else ""
        return f"$ edit {resolved}\n1 replacement applied{opened}"
    except Exception as exc:
        return f"$ edit {resolved}\n[error: {exc}]"


@tool
def create_file(file_path: str, contents: str) -> str:
    """Create a new file with the given contents.

    Parent directories are created automatically.  Refuses to overwrite
    an existing file — use edit_file for that.

    Args:
        file_path: Path for the new file
        contents: Text to write

    Returns:
        Confirmation or error message
    """
    resolved = _resolve_path(file_path)
    if resolved.exists():
        return f"$ create {resolved}\n[error: file already exists — use edit_file to modify it]"
    try:
        resolved.parent.mkdir(parents=True, exist_ok=True)
        resolved.write_text(contents)
        size = len(contents.encode())
        editor = _auto_open_project(resolved)
        opened = f" → opened project in {editor}" if editor else ""
        return f"$ create {resolved}\n{size} bytes written{opened}"
    except Exception as exc:
        return f"$ create {resolved}\n[error: {exc}]"


@tool
def search_in_files(
    pattern: str,
    directory: str = ".",
    file_glob: Optional[str] = None,
) -> str:
    """Search for a regex pattern across files using ripgrep.

    Useful for finding function definitions, usages, imports, or any
    text pattern across a codebase.

    Args:
        pattern: Regex pattern to search for
        directory: Root directory to search in (default: current directory)
        file_glob: Optional glob to filter files (e.g. "*.py", "*.rs")

    Returns:
        Matching lines with file paths and line numbers, or a message
        if nothing matched
    """
    resolved = _resolve_path(directory)
    if not resolved.is_dir():
        return f"$ rg '{pattern}' {resolved}\n[error: directory not found]"
    cmd: list[str] = [
        "rg", "--line-number", "--max-count", "50",
        "--color", "never", pattern, str(resolved),
    ]
    if file_glob:
        cmd.extend(["--glob", file_glob])
    prompt = f"$ rg '{pattern}' {resolved}"
    if file_glob:
        prompt += f" --glob '{file_glob}'"
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
        )
        output = result.stdout.strip()
        return f"{prompt}\n{output}" if output else f"{prompt}\n(no matches)"
    except FileNotFoundError:
        return f"{prompt}\n[error: ripgrep (rg) is not installed]"
    except subprocess.TimeoutExpired:
        return f"{prompt}\n[timed out after 30s]"
    except Exception as exc:
        return f"{prompt}\n[error: {exc}]"


def get_editor_tools() -> List[Any]:
    """Return all editor/filesystem tools."""
    return [open_in_editor, read_file, edit_file, create_file, search_in_files]
