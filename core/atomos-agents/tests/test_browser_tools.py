"""
Unit tests for browser tool orchestration.

- browser_local.py: CAPTCHA detection, import guard
- browser_cloud.py: credential gate, profile/session lifecycle
- browser.py: local→cloud escalation, LangChain tool interface
"""
import os
from contextlib import contextmanager

import pytest
from unittest.mock import AsyncMock, MagicMock, patch


# ---------------------------------------------------------------------------
# browser_local — CAPTCHA signal detection
# ---------------------------------------------------------------------------


class TestCaptchaDetection:
    def test_cloudflare_is_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("Just a moment... Cloudflare challenge")

    def test_recaptcha_is_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("Please complete the reCAPTCHA to continue")

    def test_hcaptcha_is_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("hCaptcha verification required")

    def test_turnstile_is_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("Turnstile challenge page")

    def test_ddos_guard_is_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("DDoS-Guard is checking your browser")

    def test_normal_output_is_not_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert not _is_captcha_blocked("GitHub trending repositories: 1. awesome-repo...")

    def test_challenges_word_is_not_captcha(self):
        from tools.browser_local import _is_captcha_blocked
        assert not _is_captcha_blocked(
            "Recent breakthroughs and challenges in room temperature quantum computing"
        )

    def test_detection_is_case_insensitive(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("CAPTCHA DETECTED")
        assert _is_captcha_blocked("Verify You Are Human")

    def test_long_final_report_is_not_captcha_final_output(self):
        from tools.browser_local import _is_captcha_final_output
        long_report = (
            "### Room-Temperature Quantum Computing Research Report\n"
            + ("Detailed findings and challenges.\n" * 200)
        )
        assert not _is_captcha_final_output(long_report)

    def test_short_cloudflare_page_is_captcha_final_output(self):
        from tools.browser_local import _is_captcha_final_output
        assert _is_captcha_final_output("Just a moment... Cloudflare challenge")


class TestBrowserLaunchDetection:
    def test_cdp_timeout_is_launch_failure(self):
        from tools.browser_local import _is_browser_launch_failure
        assert _is_browser_launch_failure(
            "Event handler browser_use.browser.watchdog_base.BrowserSession."
            "on_BrowserStartEvent timed out after 30.0s"
        )

    def test_connection_refused_is_launch_failure(self):
        from tools.browser_local import _is_browser_launch_failure
        assert _is_browser_launch_failure(
            "ConnectionRefusedError: [Errno 111] Connect call failed ('127.0.0.1', 33231)"
        )

    def test_launch_event_is_launch_failure(self):
        from tools.browser_local import _is_browser_launch_failure
        assert _is_browser_launch_failure(
            "on_BrowserLaunchEvent was interrupted because of a parent timeout"
        )

    def test_normal_timeout_is_not_launch_failure(self):
        from tools.browser_local import _is_browser_launch_failure
        assert not _is_browser_launch_failure("Task took too long to complete")

    def test_normal_output_is_not_launch_failure(self):
        from tools.browser_local import _is_browser_launch_failure
        assert not _is_browser_launch_failure("GitHub trending repos: awesome-repo")


def _local_browser_patches(mock_agent, mock_browser):
    """Return the standard set of patches for local browser runner tests."""
    return (
        patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
        patch("tools.browser_local.Agent", return_value=mock_agent),
        patch("tools.browser_local.Browser", return_value=mock_browser),
        patch("tools.browser_local.ChatOllama"),
        patch("tools.browser_local._ensure_display_env", return_value=[]),
    )


class TestLocalBrowserRunner:
    @pytest.mark.asyncio
    async def test_returns_agent_output(self):
        mock_history = MagicMock()
        mock_history.final_result.return_value = "trending repos: repo-a, repo-b"

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            result = await run_local_browser_task("find trending repos", "llama3.2")

        assert result == "trending repos: repo-a, repo-b"

    @pytest.mark.asyncio
    async def test_raises_captcha_blocked_on_captcha_output(self):
        mock_history = MagicMock()
        mock_history.final_result.return_value = "Cloudflare challenge — just a moment..."

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task, CaptchaBlockedError
            with pytest.raises(CaptchaBlockedError):
                await run_local_browser_task("search for prices", "llama3.2")

    @pytest.mark.asyncio
    async def test_raises_captcha_blocked_on_exception_containing_signal(self):
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(side_effect=RuntimeError("hcaptcha verification loop"))

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task, CaptchaBlockedError
            with pytest.raises(CaptchaBlockedError):
                await run_local_browser_task("test", "llama3.2")

    @pytest.mark.asyncio
    async def test_prepends_start_url_to_task(self):
        captured_tasks = []

        mock_history = MagicMock()
        mock_history.final_result.return_value = "result"

        class CapturingAgent:
            def __init__(self, task, llm, browser):
                captured_tasks.append(task)
            run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", CapturingAgent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            await run_local_browser_task("click login", "llama3.2", start_url="https://example.com")

        assert "https://example.com" in captured_tasks[0]
        assert "click login" in captured_tasks[0]

    @pytest.mark.asyncio
    async def test_browser_always_closed_on_exception(self):
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(side_effect=RuntimeError("network error"))

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            with pytest.raises(RuntimeError):
                await run_local_browser_task("test", "llama3.2")

        mock_browser.stop.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_missing_import_raises_runtime_error(self):
        with patch("tools.browser_local._BROWSER_USE_AVAILABLE", False):
            from tools.browser_local import run_local_browser_task
            with pytest.raises(RuntimeError, match="not installed"):
                await run_local_browser_task("test", "llama3.2")

    @pytest.mark.asyncio
    async def test_timeout_raises_timeout_error(self):
        """agent.run() exceeding the timeout should surface as TimeoutError."""
        import asyncio

        async def slow_run():
            await asyncio.sleep(10)

        mock_agent = MagicMock()
        mock_agent.run = slow_run

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            with pytest.raises(TimeoutError, match="timeout"):
                await run_local_browser_task("test", "llama3.2", timeout=0.05)

        mock_browser.stop.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_bubus_browser_start_timeout_raises_launch_error(self):
        """TimeoutError from browser-use's BrowserStartEvent should become BrowserLaunchError."""
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=TimeoutError(
                "Event handler browser_use.browser.watchdog_base.BrowserSession."
                "on_BrowserStartEvent timed out after 30.0s"
            )
        )

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task, BrowserLaunchError
            with pytest.raises(BrowserLaunchError):
                await run_local_browser_task("test", "llama3.2")

    @pytest.mark.asyncio
    async def test_generic_timeout_error_propagates_as_timeout(self):
        """A non-launch TimeoutError should propagate as TimeoutError with context."""
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=TimeoutError("some other timeout")
        )

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task, BrowserLaunchError
            with pytest.raises(TimeoutError, match="timeout") as exc_info:
                await run_local_browser_task("test", "llama3.2")
            assert not isinstance(exc_info.value, BrowserLaunchError)

    @pytest.mark.asyncio
    async def test_connection_refused_raises_launch_error(self):
        """ConnectionRefusedError from CDP port should become BrowserLaunchError."""
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=RuntimeError(
                "ConnectionRefusedError: [Errno 111] Connect call failed ('127.0.0.1', 33231)"
            )
        )

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task, BrowserLaunchError
            with pytest.raises(BrowserLaunchError):
                await run_local_browser_task("test", "llama3.2")


# ---------------------------------------------------------------------------
# run_local_browser_session — persistent local session
# ---------------------------------------------------------------------------



class TestLocalBrowserSession:
    @pytest.mark.asyncio
    async def test_returns_results_for_each_task(self):
        mock_history = MagicMock()
        mock_history.final_result.return_value = "result"

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
        ):
            from tools.browser_local import run_local_browser_session
            results = await run_local_browser_session(
                ["task 1", "task 2"], "llama3.2"
            )

        assert results == ["result", "result"]

    @pytest.mark.asyncio
    async def test_reuses_same_browser_across_tasks(self):
        mock_history = MagicMock()
        mock_history.final_result.return_value = "ok"

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        mock_browser_cls = MagicMock(return_value=mock_browser)

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", mock_browser_cls),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
        ):
            from tools.browser_local import run_local_browser_session
            await run_local_browser_session(["t1", "t2", "t3"], "llama3.2")

        # Browser constructed once, not once per task
        mock_browser_cls.assert_called_once()

    @pytest.mark.asyncio
    async def test_browser_created_with_keep_alive(self):
        mock_history = MagicMock()
        mock_history.final_result.return_value = "ok"

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(return_value=mock_history)

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        mock_browser_cls = MagicMock(return_value=mock_browser)

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", mock_browser_cls),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
        ):
            from tools.browser_local import run_local_browser_session
            await run_local_browser_session(["task"], "llama3.2")

        _, kwargs = mock_browser_cls.call_args
        assert kwargs.get("keep_alive") is True
        assert kwargs.get("headless") is False

    @pytest.mark.asyncio
    async def test_missing_import_raises_runtime_error(self):
        with patch("tools.browser_local._BROWSER_USE_AVAILABLE", False):
            from tools.browser_local import run_local_browser_session
            with pytest.raises(RuntimeError, match="not installed"):
                await run_local_browser_session(["task"], "llama3.2")

    @pytest.mark.asyncio
    async def test_launch_failure_raises_browser_launch_error(self):
        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=TimeoutError(
                "on_BrowserStartEvent timed out after 30.0s"
            )
        )

        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local.ChatOllama"),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
        ):
            from tools.browser_local import run_local_browser_session, BrowserLaunchError
            with pytest.raises(BrowserLaunchError):
                await run_local_browser_session(["task"], "llama3.2")

    @pytest.mark.asyncio
    async def test_close_session_stops_browser(self):
        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        fake_sessions = {"my-session": mock_browser}

        with patch("tools.browser_local._sessions", fake_sessions):
            from tools.browser_local import close_local_browser_session
            await close_local_browser_session("my-session")

        mock_browser.stop.assert_awaited_once()
        assert "my-session" not in fake_sessions

    @pytest.mark.asyncio
    async def test_close_nonexistent_session_is_noop(self):
        with patch("tools.browser_local._sessions", {}):
            from tools.browser_local import close_local_browser_session
            await close_local_browser_session("ghost")  # should not raise


# ---------------------------------------------------------------------------
# _ensure_display_env — Wayland/X11 display environment injection
# ---------------------------------------------------------------------------


class TestEnsureDisplayEnv:
    def test_wayland_returns_ozone_arg(self):
        from tools.browser_local import _ensure_display_env
        with patch.dict("os.environ", {"WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000"}, clear=True):
            args = _ensure_display_env()
            assert "--ozone-platform=wayland" in args
            assert os.environ["WAYLAND_DISPLAY"] == "wayland-1"

    def test_x11_returns_no_ozone_arg(self):
        from tools.browser_local import _ensure_display_env
        with patch.dict("os.environ", {"DISPLAY": ":0"}, clear=True):
            args = _ensure_display_env()
            assert args == []
            assert os.environ["DISPLAY"] == ":0"

    def test_no_display_raises_browser_launch_error(self):
        from tools.browser_local import _ensure_display_env, BrowserLaunchError
        with (
            patch.dict("os.environ", {}, clear=True),
            patch("tools.browser_local._find_wayland_socket", return_value=(None, None)),
        ):
            with pytest.raises(BrowserLaunchError):
                _ensure_display_env()

    def test_probe_sets_os_environ_and_returns_ozone_arg(self):
        """_find_wayland_socket() result is injected into os.environ."""
        from tools.browser_local import _ensure_display_env
        with (
            patch.dict("os.environ", {}, clear=True),
            patch(
                "tools.browser_local._find_wayland_socket",
                return_value=("/run/user/1000", "wayland-1"),
            ),
        ):
            args = _ensure_display_env()
            assert os.environ["WAYLAND_DISPLAY"] == "wayland-1"
            assert os.environ["XDG_RUNTIME_DIR"] == "/run/user/1000"
            assert "--ozone-platform=wayland" in args

    def test_env_vars_take_precedence_over_probe(self):
        """Existing env vars prevent the probe from running."""
        from tools.browser_local import _ensure_display_env
        mock_probe = MagicMock(return_value=("/run/user/999", "wayland-0"))
        with (
            patch.dict("os.environ", {"WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000"}, clear=True),
            patch("tools.browser_local._find_wayland_socket", mock_probe),
        ):
            _ensure_display_env()
        mock_probe.assert_not_called()


# ---------------------------------------------------------------------------
# browser_cloud — credential gate
# ---------------------------------------------------------------------------

class TestCloudBrowserRunner:
    @pytest.mark.asyncio
    async def test_raises_credential_required_when_no_key(self):
        from secret_store import CredentialRequiredError

        with patch("tools.browser_cloud._get_browser_use_api_key", return_value=None):
            from tools.browser_cloud import run_cloud_browser_task
            with pytest.raises(CredentialRequiredError) as exc_info:
                await run_cloud_browser_task("find repos")

        assert exc_info.value.key == "browser_use_api_key"

    @pytest.mark.asyncio
    async def test_runs_task_with_key(self):
        mock_result = MagicMock()
        mock_result.output = "cloud result"
        mock_result.id = "task-123"
        mock_result.status = "finished"

        mock_client = MagicMock()
        mock_client.run = AsyncMock(return_value=mock_result)

        with patch("tools.browser_cloud._get_cloud_client", return_value=mock_client):
            from tools.browser_cloud import run_cloud_browser_task
            result = await run_cloud_browser_task("find repos")

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_session_is_stopped_after_tasks(self):
        mock_session = MagicMock()
        mock_session.id = "session-456"

        mock_task_result = MagicMock()
        mock_task_result.output = "done"

        mock_client = MagicMock()
        mock_client.sessions.create = AsyncMock(return_value=mock_session)
        mock_client.sessions.stop = AsyncMock()
        mock_client.profiles.list = AsyncMock(return_value=[])
        mock_client.run = AsyncMock(return_value=mock_task_result)

        with patch("tools.browser_cloud._get_cloud_client", return_value=mock_client):
            from tools.browser_cloud import run_cloud_browser_session
            await run_cloud_browser_session(["task 1", "task 2"])

        mock_client.sessions.stop.assert_awaited_once_with("session-456")

    @pytest.mark.asyncio
    async def test_session_stopped_even_on_task_failure(self):
        mock_session = MagicMock()
        mock_session.id = "session-789"

        mock_client = MagicMock()
        mock_client.sessions.create = AsyncMock(return_value=mock_session)
        mock_client.sessions.stop = AsyncMock()
        mock_client.profiles.list = AsyncMock(return_value=[])
        mock_client.run = AsyncMock(side_effect=RuntimeError("task failed"))

        with patch("tools.browser_cloud._get_cloud_client", return_value=mock_client):
            from tools.browser_cloud import run_cloud_browser_session
            with pytest.raises(RuntimeError):
                await run_cloud_browser_session(["failing task"])

        mock_client.sessions.stop.assert_awaited_once_with("session-789")

    @pytest.mark.asyncio
    async def test_reads_key_from_file(self):
        """_get_browser_use_api_key reads from ~/.browser_use first."""
        from tools.browser_cloud import _get_browser_use_api_key
        with patch("tools.browser_cloud._read_browser_use_key_file", return_value="bu_test_key"):
            assert _get_browser_use_api_key() == "bu_test_key"

    @pytest.mark.asyncio
    async def test_falls_back_to_secret_store(self):
        """When file is missing, falls back to secret_store.get_secret."""
        from tools.browser_cloud import _get_browser_use_api_key
        with (
            patch("tools.browser_cloud._read_browser_use_key_file", return_value=None),
            patch.dict("os.environ", {}, clear=True),
            patch("tools.browser_cloud.Path") as MockPath,
        ):
            MockPath.home.return_value = MagicMock()
            MockPath.home.return_value.__truediv__ = lambda s, n: MagicMock()
            mock_home_dir = MagicMock()
            mock_home_dir.iterdir.return_value = []
            MockPath.side_effect = lambda p: mock_home_dir if p == "/home" else MagicMock()
            with patch("tools.browser_cloud.get_secret", return_value="bu_from_store"):
                assert _get_browser_use_api_key() == "bu_from_store"


# ---------------------------------------------------------------------------
# browser.py — LangChain tool orchestration
# ---------------------------------------------------------------------------


class TestBrowseWebTool:
    def test_set_local_model_updates_module_state(self):
        from tools.browser import set_local_model
        import tools.browser as bm
        set_local_model("mistral")
        assert bm._local_model == "mistral"
        set_local_model("llama3.2")  # restore default

    # -- Cloud-first: when ~/.browser_use key exists, go straight to cloud --

    @pytest.mark.asyncio
    async def test_uses_cloud_when_key_exists(self):
        """With a ~/.browser_use key, browse_web goes directly to cloud."""
        mock_cloud = AsyncMock(return_value="cloud result")
        mock_local = AsyncMock(return_value="should not be called")

        with (
            patch("tools.browser._get_browser_use_api_key", return_value="bu_test"),
            patch("tools.browser.run_cloud_browser_task", new=mock_cloud),
            patch("tools.browser.run_local_browser_task", new=mock_local),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find trending repos"})

        assert result == "cloud result"
        mock_cloud.assert_awaited_once()
        mock_local.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_session_uses_cloud_when_key_exists(self):
        """With a ~/.browser_use key, browse_web_with_session goes to cloud."""
        mock_cloud = AsyncMock(return_value=["r1", "r2"])
        mock_local = AsyncMock(return_value=["should not be called"])

        with (
            patch("tools.browser._get_browser_use_api_key", return_value="bu_test"),
            patch("tools.browser.run_cloud_browser_session", new=mock_cloud),
            patch("tools.browser.run_local_browser_session", new=mock_local),
        ):
            from tools.browser import browse_web_with_session
            result = await browse_web_with_session.ainvoke(
                {"tasks": ["log in", "check inbox"]}
            )

        assert result == ["r1", "r2"]
        mock_cloud.assert_awaited_once()
        mock_local.assert_not_awaited()

    # -- Local fallback: when no key, try local first then escalate ----------

    @pytest.mark.asyncio
    async def test_returns_local_result_when_no_key(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(return_value="local result"),
            ),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find trending repos"})

        assert result == "local result"

    @pytest.mark.asyncio
    async def test_escalates_to_cloud_on_captcha(self):
        from tools.browser_local import CaptchaBlockedError

        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(side_effect=CaptchaBlockedError("blocked")),
            ),
            patch(
                "tools.browser.run_cloud_browser_task",
                new=AsyncMock(return_value="cloud result"),
            ),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find price"})

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_raises_credential_required_when_captcha_and_no_key(self):
        from tools.browser_local import CaptchaBlockedError
        from secret_store import CredentialRequiredError

        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(side_effect=CaptchaBlockedError("blocked")),
            ),
            patch(
                "tools.browser.run_cloud_browser_task",
                new=AsyncMock(side_effect=CredentialRequiredError("browser_use_api_key")),
            ),
        ):
            from tools.browser import browse_web
            with pytest.raises(CredentialRequiredError) as exc_info:
                await browse_web.ainvoke({"task": "scrape protected page"})

        assert exc_info.value.key == "browser_use_api_key"

    @pytest.mark.asyncio
    async def test_escalates_to_cloud_on_timeout(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(side_effect=TimeoutError("agent task timed out")),
            ),
            patch(
                "tools.browser.run_cloud_browser_task",
                new=AsyncMock(return_value="cloud result"),
            ),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find repos"})

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_escalates_to_cloud_on_browser_launch_error(self):
        from tools.browser_local import BrowserLaunchError

        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(side_effect=BrowserLaunchError("Chromium failed to start")),
            ),
            patch(
                "tools.browser.run_cloud_browser_task",
                new=AsyncMock(return_value="cloud result"),
            ),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find repos"})

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_escalates_to_cloud_on_os_error(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_task",
                new=AsyncMock(side_effect=OSError("chromium binary not found")),
            ),
            patch(
                "tools.browser.run_cloud_browser_task",
                new=AsyncMock(return_value="cloud result"),
            ),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find repos"})

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_empty_local_result_escalates_to_cloud(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value="bu_test"),
            patch("tools.browser.run_local_browser_task", new=AsyncMock(return_value="")),
            patch("tools.browser.run_cloud_browser_task", new=AsyncMock(return_value="cloud result")),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find repos"})

        assert result == "cloud result"

    @pytest.mark.asyncio
    async def test_cloud_timeout_returns_user_message(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value="bu_test"),
            patch("tools.browser.run_local_browser_task", new=AsyncMock(side_effect=TimeoutError("local timeout"))),
            patch("tools.browser.run_cloud_browser_task", new=AsyncMock(side_effect=TimeoutError("cloud timeout"))),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find repos"})

        assert "timed out" in result.lower()

    @pytest.mark.asyncio
    async def test_cloud_not_called_when_local_succeeds_and_no_key(self):
        mock_cloud = AsyncMock(return_value="should not be called")

        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch("tools.browser.run_local_browser_task", new=AsyncMock(return_value="local ok")),
            patch("tools.browser.run_cloud_browser_task", new=mock_cloud),
        ):
            from tools.browser import browse_web
            await browse_web.ainvoke({"task": "simple task"})

        mock_cloud.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_browse_web_with_session_calls_local_when_no_key(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_session",
                new=AsyncMock(return_value=["r1", "r2"]),
            ) as mock_session,
        ):
            from tools.browser import browse_web_with_session
            result = await browse_web_with_session.ainvoke(
                {"tasks": ["log in", "check inbox"]}
            )

        mock_session.assert_awaited_once()
        assert result == ["r1", "r2"]

    @pytest.mark.asyncio
    async def test_browse_web_with_session_passes_session_name(self):
        with (
            patch("tools.browser._get_browser_use_api_key", return_value=None),
            patch(
                "tools.browser.run_local_browser_session",
                new=AsyncMock(return_value=["done"]),
            ) as mock_session,
        ):
            from tools.browser import browse_web_with_session
            await browse_web_with_session.ainvoke(
                {"tasks": ["do thing"], "session_name": "work"}
            )

        call_kwargs = mock_session.call_args
        assert "work" in call_kwargs.args or call_kwargs.kwargs.get("session_name") == "work"

    def test_get_browser_tools_returns_two_tools(self):
        from tools.browser import get_browser_tools
        tools = get_browser_tools()
        names = [t.name for t in tools]
        assert "browse_web" in names
        assert "browse_web_with_session" in names
        assert len(tools) == 2


# ---------------------------------------------------------------------------
# _make_browser_llm — real LLM classes, no fakes
#
# These tests use the REAL langchain Pydantic v2 model classes (ChatOpenAI,
# ChatGroq, ChatOllama) so that Pydantic __getattr__ / __setattr__
# restrictions are exercised the same way they are in production.  Only
# Agent and Browser (which need a running Chromium) are mocked.
# ---------------------------------------------------------------------------

from langchain_openai import ChatOpenAI as RealChatOpenAI
from langchain_groq import ChatGroq as RealChatGroq
from langchain_ollama import ChatOllama as RealChatOllama


class _StubChatBrowserUse:
    """Minimal stub for browser-use's ChatBrowserUse (not pip-installable in dev)."""
    provider = "browser-use"

    def __init__(self, api_key=None):
        self.api_key = api_key


@contextmanager
def _patch_browser_use_only():
    """Patch _ChatBrowserUse (not installed in dev); leave real LLM classes alone."""
    with patch("tools.browser_local._ChatBrowserUse", _StubChatBrowserUse):
        yield


@contextmanager
def _patch_ollama_for_dev():
    """In dev, browser_use isn't installed so ChatOllama is None.

    Patch it with the real langchain_ollama ChatOllama (which is what
    browser_use re-exports) so the Ollama path can be tested.
    """
    from tools.browser_local import _browser_safe_cls
    safe = _browser_safe_cls(RealChatOllama)
    with patch("tools.browser_local.ChatOllama", safe):
        yield


class TestMakeBrowserLlm:
    """Verify _make_browser_llm picks the right backend in priority order.

    Uses real langchain LLM classes — NOT mocks.
    """

    def test_browser_use_takes_top_priority(self):
        with _patch_browser_use_only():
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "any-model", is_cloud=True, groq_api_key="gsk_x",
                browser_use_api_key="bu_key", openrouter_api_key="or_key",
            )
            assert isinstance(llm, _StubChatBrowserUse)

    def test_openrouter_returns_real_chat_openai(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "z-ai/glm-5", is_cloud=True, groq_api_key="gsk_x",
                openrouter_api_key="or_key",
            )
            assert isinstance(llm, RealChatOpenAI)

    def test_openrouter_when_browser_use_class_missing(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "z-ai/glm-5", is_cloud=False, groq_api_key=None,
                browser_use_api_key="bu_key", openrouter_api_key="or_key",
            )
            assert isinstance(llm, RealChatOpenAI)

    def test_groq_returns_real_chat_groq(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama-4", is_cloud=True, groq_api_key="gsk_x",
            )
            assert isinstance(llm, RealChatGroq)

    def test_ollama_returns_real_chat_ollama(self):
        with (
            patch("tools.browser_local._ChatBrowserUse", None),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama3.2", is_cloud=False, groq_api_key=None,
            )
            assert isinstance(llm, RealChatOllama)

    def test_groq_skip_model_is_replaced(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm, _BROWSER_GROQ_FALLBACK
            llm = _make_browser_llm(
                "meta-llama/llama-4-maverick-17b-128e-instruct",
                is_cloud=True, groq_api_key="gsk_x",
            )
            assert isinstance(llm, RealChatGroq)
            assert llm.model_name == _BROWSER_GROQ_FALLBACK


# ---------------------------------------------------------------------------
# browser-use Agent interface contract
#
# browser-use Agent.__init__ does two things to the LLM that break
# Pydantic v2 models:
#
#   1. Reads llm.provider (agent/service.py:233)
#      → Pydantic __getattr__ raises AttributeError
#
#   2. token_cost_service.register_llm(llm) does
#      setattr(llm, 'ainvoke', tracked_ainvoke) (tokens/service.py:361)
#      → Pydantic __setattr__ raises ValueError for non-field names
#
# These tests use the REAL Pydantic models and reproduce the exact
# operations that crashed in production.
# ---------------------------------------------------------------------------


class TestBrowserUseCompatContract:
    """LLMs from _make_browser_llm must survive browser-use's internal ops."""

    def test_openrouter_provider_read(self):
        """agent/service.py:233  →  if llm.provider == 'browser-use'"""
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "z-ai/glm-5", is_cloud=False, groq_api_key=None,
                openrouter_api_key="or_key",
            )
        assert hasattr(llm, "provider")
        assert llm.provider == "openrouter"

    def test_openrouter_setattr_ainvoke(self):
        """tokens/service.py:361  →  setattr(llm, 'ainvoke', tracked)"""
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "z-ai/glm-5", is_cloud=False, groq_api_key=None,
                openrouter_api_key="or_key",
            )
        sentinel = object()
        setattr(llm, "ainvoke", sentinel)
        assert llm.ainvoke is sentinel

    def test_groq_provider_read(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama-4", is_cloud=True, groq_api_key="gsk_x",
            )
        assert hasattr(llm, "provider")
        assert llm.provider == "groq"

    def test_groq_setattr_ainvoke(self):
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama-4", is_cloud=True, groq_api_key="gsk_x",
            )
        sentinel = object()
        setattr(llm, "ainvoke", sentinel)
        assert llm.ainvoke is sentinel

    def test_ollama_provider_read(self):
        with (
            patch("tools.browser_local._ChatBrowserUse", None),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama3.2", is_cloud=False, groq_api_key=None,
            )
        assert hasattr(llm, "provider")
        assert llm.provider == "ollama"

    def test_ollama_setattr_ainvoke(self):
        with (
            patch("tools.browser_local._ChatBrowserUse", None),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import _make_browser_llm
            llm = _make_browser_llm(
                "llama3.2", is_cloud=False, groq_api_key=None,
            )
        sentinel = object()
        setattr(llm, "ainvoke", sentinel)
        assert llm.ainvoke is sentinel

    def test_provider_survives_agent_init_check(self):
        """Reproduce the exact line from browser_use/agent/service.py:233."""
        with patch("tools.browser_local._ChatBrowserUse", None):
            from tools.browser_local import _make_browser_llm
            for label, kwargs in [
                ("openrouter", dict(
                    model_name="z-ai/glm-5", is_cloud=False,
                    groq_api_key=None, openrouter_api_key="or_key",
                )),
                ("groq", dict(
                    model_name="llama-4", is_cloud=True,
                    groq_api_key="gsk_x",
                )),
            ]:
                llm = _make_browser_llm(**kwargs)
                is_bu = llm.provider == "browser-use"
                assert not is_bu, f"{label} LLM should not be 'browser-use'"

    def test_set_provider_is_idempotent(self):
        """Calling _set_provider twice must not overwrite the first value."""
        from tools.browser_local import _set_provider, BrowserChatOpenAI
        llm = BrowserChatOpenAI(api_key="test", model="test")
        _set_provider(llm, "first")
        _set_provider(llm, "second")
        assert llm.provider == "first"

    def test_raw_chat_openai_rejects_setattr(self):
        """Verify the raw (unwrapped) ChatOpenAI from langchain DOES reject setattr.

        This proves our safe subclass is necessary — without it, browser-use
        would crash with ValueError.
        """
        raw = RealChatOpenAI(api_key="test", model="test")
        with pytest.raises((ValueError, AttributeError)):
            setattr(raw, "some_nonexistent_attr", "value")

    def test_raw_chat_groq_rejects_setattr(self):
        """Same proof for ChatGroq."""
        raw = RealChatGroq(api_key="test", model="test")
        with pytest.raises((ValueError, AttributeError)):
            setattr(raw, "some_nonexistent_attr", "value")


# ---------------------------------------------------------------------------
# _browser_safe_cls — the subclassing mechanism
# ---------------------------------------------------------------------------


class TestBrowserSafeCls:
    def test_returns_none_for_none(self):
        from tools.browser_local import _browser_safe_cls
        assert _browser_safe_cls(None) is None

    def test_subclass_preserves_class_name(self):
        from tools.browser_local import _browser_safe_cls
        safe = _browser_safe_cls(RealChatOpenAI)
        assert safe.__name__ == "ChatOpenAI"

    def test_subclass_is_subclass(self):
        from tools.browser_local import _browser_safe_cls
        safe = _browser_safe_cls(RealChatOpenAI)
        assert issubclass(safe, RealChatOpenAI)

    def test_instances_pass_isinstance_check(self):
        from tools.browser_local import _browser_safe_cls
        safe = _browser_safe_cls(RealChatOpenAI)
        llm = safe(api_key="test", model="test")
        assert isinstance(llm, RealChatOpenAI)

    def test_pydantic_fields_still_validated(self):
        """Normal Pydantic field assignment must still go through validation."""
        from tools.browser_local import _browser_safe_cls
        safe = _browser_safe_cls(RealChatOpenAI)
        llm = safe(api_key="test", model="test")
        llm.temperature = 0.5
        assert llm.temperature == 0.5


# ---------------------------------------------------------------------------
# run_local_browser_task — real LLMs, mocked Agent + Browser
# ---------------------------------------------------------------------------


def _make_successful_agent_and_browser():
    mock_history = MagicMock()
    mock_history.final_result.return_value = "ok"
    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(return_value=mock_history)
    mock_browser = MagicMock()
    mock_browser.stop = AsyncMock()
    return mock_agent, mock_browser


class TestLocalBrowserRunnerLlmPaths:
    """Verify run_local_browser_task creates the right LLM for each backend.

    Agent and Browser are mocked (need real Chromium); LLM classes are real.
    """

    @pytest.mark.asyncio
    async def test_openrouter_path(self):
        mock_agent, mock_browser = _make_successful_agent_and_browser()
        captured_llm = []

        def capture_agent(**kw):
            captured_llm.append(kw["llm"])
            return mock_agent

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local._ChatBrowserUse", None),
            patch("tools.browser_local.Agent", side_effect=capture_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            await run_local_browser_task(
                "test", "z-ai/glm-5",
                openrouter_api_key="or_key",
            )

        assert len(captured_llm) == 1
        assert isinstance(captured_llm[0], RealChatOpenAI)
        assert captured_llm[0].provider == "openrouter"

    @pytest.mark.asyncio
    async def test_groq_path(self):
        mock_agent, mock_browser = _make_successful_agent_and_browser()
        captured_llm = []

        def capture_agent(**kw):
            captured_llm.append(kw["llm"])
            return mock_agent

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local._ChatBrowserUse", None),
            patch("tools.browser_local.Agent", side_effect=capture_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            await run_local_browser_task(
                "test", "llama-4",
                is_cloud=True, groq_api_key="gsk_x",
            )

        assert len(captured_llm) == 1
        assert isinstance(captured_llm[0], RealChatGroq)
        assert captured_llm[0].provider == "groq"

    @pytest.mark.asyncio
    async def test_cloud_kwargs_applied_for_cloud_model(self):
        """is_cloud=True must inject flash_mode, max_failures, etc."""
        mock_agent, mock_browser = _make_successful_agent_and_browser()
        captured_kwargs = []

        def capture_agent(**kw):
            captured_kwargs.append(kw)
            return mock_agent

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local._ChatBrowserUse", None),
            patch("tools.browser_local.Agent", side_effect=capture_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
        ):
            from tools.browser_local import run_local_browser_task
            await run_local_browser_task(
                "test", "llama-4",
                is_cloud=True, groq_api_key="gsk_x",
            )

        kw = captured_kwargs[0]
        assert kw.get("flash_mode") is True
        assert kw.get("use_judge") is False
        assert kw.get("max_failures") == 1

    @pytest.mark.asyncio
    async def test_local_ollama_no_cloud_kwargs(self):
        """Pure local Ollama must NOT inject cloud-specific Agent kwargs."""
        mock_agent, mock_browser = _make_successful_agent_and_browser()
        captured_kwargs = []

        def capture_agent(**kw):
            captured_kwargs.append(kw)
            return mock_agent

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local._ChatBrowserUse", None),
            patch("tools.browser_local.Agent", side_effect=capture_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import run_local_browser_task
            await run_local_browser_task("test", "llama3.2")

        kw = captured_kwargs[0]
        assert "flash_mode" not in kw
        assert "max_failures" not in kw


# ---------------------------------------------------------------------------
# run_local_browser_session — rate limit + launch failure handling
# ---------------------------------------------------------------------------


class TestLocalBrowserSessionErrorHandling:

    @pytest.mark.asyncio
    async def test_session_rate_limit_raises(self):
        from tools.browser_local import RateLimitError

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=RuntimeError("rate_limit_exceeded: tokens per minute")
        )
        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import run_local_browser_session
            with pytest.raises(RateLimitError):
                await run_local_browser_session(["task"], "llama3.2")

    @pytest.mark.asyncio
    async def test_session_rate_limit_429_raises(self):
        from tools.browser_local import RateLimitError

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=RuntimeError("Error code: 429 — too many requests")
        )
        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import run_local_browser_session
            with pytest.raises(RateLimitError):
                await run_local_browser_session(["task"], "llama3.2")

    @pytest.mark.asyncio
    async def test_session_launch_failure_in_task_raises(self):
        from tools.browser_local import BrowserLaunchError

        mock_agent = MagicMock()
        mock_agent.run = AsyncMock(
            side_effect=RuntimeError("ConnectionRefusedError: Connect call failed")
        )
        mock_browser = MagicMock()
        mock_browser.stop = AsyncMock()

        with (
            patch("tools.browser_local._BROWSER_USE_AVAILABLE", True),
            patch("tools.browser_local.Agent", return_value=mock_agent),
            patch("tools.browser_local.Browser", return_value=mock_browser),
            patch("tools.browser_local._ensure_display_env", return_value=[]),
            patch("tools.browser_local._sessions", {}),
            _patch_ollama_for_dev(),
        ):
            from tools.browser_local import run_local_browser_session
            with pytest.raises(BrowserLaunchError):
                await run_local_browser_session(["task"], "llama3.2")


# ---------------------------------------------------------------------------
# Rate-limit detection helpers
# ---------------------------------------------------------------------------


class TestRateLimitDetection:
    def test_rate_limit_exceeded_detected(self):
        from tools.browser_local import _is_rate_limit_error
        assert _is_rate_limit_error("rate_limit_exceeded")

    def test_429_detected(self):
        from tools.browser_local import _is_rate_limit_error
        assert _is_rate_limit_error("Error code: 429 Too Many Requests")

    def test_413_detected(self):
        from tools.browser_local import _is_rate_limit_error
        assert _is_rate_limit_error("HTTP 413: Request Entity Too Large")

    def test_tokens_per_minute_detected(self):
        from tools.browser_local import _is_rate_limit_error
        assert _is_rate_limit_error("exceeded tokens per minute limit for this model")

    def test_normal_error_not_rate_limit(self):
        from tools.browser_local import _is_rate_limit_error
        assert not _is_rate_limit_error("network timeout after 30s")

    def test_normal_output_not_rate_limit(self):
        from tools.browser_local import _is_rate_limit_error
        assert not _is_rate_limit_error("trending repos: repo-a, repo-b")


class TestLocalTimeoutConfig:
    def test_default_timeout_is_300(self):
        from tools.browser_local import _read_local_browser_timeout
        with patch.dict("os.environ", {}, clear=True):
            assert _read_local_browser_timeout() == 300

    def test_invalid_timeout_falls_back_to_300(self):
        from tools.browser_local import _read_local_browser_timeout
        with patch.dict("os.environ", {"BROWSER_LOCAL_TIMEOUT_SECONDS": "abc"}, clear=True):
            assert _read_local_browser_timeout() == 300

    def test_timeout_is_bounded(self):
        from tools.browser_local import _read_local_browser_timeout
        with patch.dict("os.environ", {"BROWSER_LOCAL_TIMEOUT_SECONDS": "5"}, clear=True):
            assert _read_local_browser_timeout() == 30
        with patch.dict("os.environ", {"BROWSER_LOCAL_TIMEOUT_SECONDS": "99999"}, clear=True):
            assert _read_local_browser_timeout() == 1800


class TestCloudTimeoutConfig:
    def test_default_timeout_is_300(self):
        from tools.browser_cloud import _read_cloud_browser_timeout
        with patch.dict("os.environ", {}, clear=True):
            assert _read_cloud_browser_timeout() == 300

    def test_invalid_timeout_falls_back_to_300(self):
        from tools.browser_cloud import _read_cloud_browser_timeout
        with patch.dict("os.environ", {"BROWSER_CLOUD_TIMEOUT_SECONDS": "abc"}, clear=True):
            assert _read_cloud_browser_timeout() == 300
