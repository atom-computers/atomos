"""
Unit tests for browser tool orchestration.

- browser_local.py: CAPTCHA detection, import guard
- browser_cloud.py: credential gate, profile/session lifecycle
- browser.py: local→cloud escalation, LangChain tool interface
"""
import os

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

    def test_detection_is_case_insensitive(self):
        from tools.browser_local import _is_captcha_blocked
        assert _is_captcha_blocked("CAPTCHA DETECTED")
        assert _is_captcha_blocked("Verify You Are Human")


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

        with patch("tools.browser_cloud.require_secret", side_effect=CredentialRequiredError("browser_use_api_key")):
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

        with (
            patch("tools.browser_cloud.require_secret", return_value="real_api_key"),
            patch("tools.browser_cloud._get_cloud_client", return_value=mock_client),
        ):
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

        with (
            patch("tools.browser_cloud.require_secret", return_value="key"),
            patch("tools.browser_cloud._get_cloud_client", return_value=mock_client),
        ):
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

        with (
            patch("tools.browser_cloud.require_secret", return_value="key"),
            patch("tools.browser_cloud._get_cloud_client", return_value=mock_client),
        ):
            from tools.browser_cloud import run_cloud_browser_session
            with pytest.raises(RuntimeError):
                await run_cloud_browser_session(["failing task"])

        mock_client.sessions.stop.assert_awaited_once_with("session-789")


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

    @pytest.mark.asyncio
    async def test_returns_local_result_on_success(self):
        with patch(
            "tools.browser.run_local_browser_task",
            new=AsyncMock(return_value="local result"),
        ):
            from tools.browser import browse_web
            result = await browse_web.ainvoke({"task": "find trending repos"})

        assert result == "local result"

    @pytest.mark.asyncio
    async def test_escalates_to_cloud_on_captcha(self):
        from tools.browser_local import CaptchaBlockedError

        with (
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
    async def test_cloud_not_called_when_local_succeeds(self):
        mock_cloud = AsyncMock(return_value="should not be called")

        with (
            patch("tools.browser.run_local_browser_task", new=AsyncMock(return_value="local ok")),
            patch("tools.browser.run_cloud_browser_task", new=mock_cloud),
        ):
            from tools.browser import browse_web
            await browse_web.ainvoke({"task": "simple task"})

        mock_cloud.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_browse_web_with_session_calls_local_session(self):
        with patch(
            "tools.browser.run_local_browser_session",
            new=AsyncMock(return_value=["r1", "r2"]),
        ) as mock_session:
            from tools.browser import browse_web_with_session
            result = await browse_web_with_session.ainvoke(
                {"tasks": ["log in", "check inbox"]}
            )

        mock_session.assert_awaited_once()
        assert result == ["r1", "r2"]

    @pytest.mark.asyncio
    async def test_browse_web_with_session_passes_session_name(self):
        with patch(
            "tools.browser.run_local_browser_session",
            new=AsyncMock(return_value=["done"]),
        ) as mock_session:
            from tools.browser import browse_web_with_session
            await browse_web_with_session.ainvoke(
                {"tasks": ["do thing"], "session_name": "work"}
            )

        call_kwargs = mock_session.call_args
        assert "work" in call_kwargs.args or call_kwargs.kwargs.get("session_name") == "work"

    @pytest.mark.asyncio
    async def test_browse_web_with_session_does_not_call_cloud(self):
        mock_cloud = AsyncMock(return_value=["should not be called"])

        with (
            patch("tools.browser.run_local_browser_session", new=AsyncMock(return_value=["ok"])),
            patch("tools.browser.run_cloud_browser_task", new=mock_cloud),
        ):
            from tools.browser import browse_web_with_session
            await browse_web_with_session.ainvoke({"tasks": ["task"]})

        mock_cloud.assert_not_awaited()

    def test_get_browser_tools_returns_two_tools(self):
        from tools.browser import get_browser_tools
        tools = get_browser_tools()
        names = [t.name for t in tools]
        assert "browse_web" in names
        assert "browse_web_with_session" in names
        assert len(tools) == 2
