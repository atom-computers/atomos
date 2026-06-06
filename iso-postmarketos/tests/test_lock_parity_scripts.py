import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ISO_ROOT = REPO_ROOT / "iso-postmarketos"
SCRIPTS = ISO_ROOT / "scripts"
S_OVERVIEW = SCRIPTS / "overview-chat-ui"
S_PMB = SCRIPTS / "pmb"
S_PHOSH = SCRIPTS / "phosh"
S_APP_HANDLER = SCRIPTS / "app-handler"
S_ROOTFS = SCRIPTS / "rootfs"
S_VALIDATE = SCRIPTS / "validate"
S_DEVICE = SCRIPTS / "device"
R_APP_HANDLER_HANDLE_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-app-handler"
    / "app-gtk"
    / "src"
    / "linux"
    / "handle.rs"
)
R_APP_HANDLER_HANDLE_CORE = (
    ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "handle.rs"
)
R_APP_HANDLER_CORE_LIB = ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "lib.rs"
PHOSH_SHELL_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "shell.c"
PHOSH_OVERVIEW_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "overview.c"
PHOSH_APP_GRID_BUTTON_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "app-grid-button.c"
PHOSH_ATOMOS_HOME_DBUS_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "atomos-phosh-home-dbus.c"
PHOSH_ATOMOS_HOME_DBUS_XML = (
    ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "dbus" / "org.atomos.PhoshHome.xml"
)
STYLE_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "style.rs"
)
PHOSH_HOME_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "home.c"
PHOSH_TOP_PANEL_C = ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "top-panel.c"


def run_script(path, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        ["bash", str(path), *map(str, args)],
        check=False,
        text=True,
        capture_output=True,
        env=merged_env,
    )


class TestOverlayAndValidationTemplateModes(unittest.TestCase):
    def test_apply_overlay_dump_mode_replaces_lock_placeholder_enabled(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text('PMOS_LOCK_PARITY="1"\n', encoding="utf-8")
            result = run_script(
                S_ROOTFS / "apply-overlay.sh",
                profile,
                env={"ATOMOS_OVERLAY_DUMP_ONLY": "1", "ATOMOS_LOCK_PARITY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn('if [ "1" = "1" ]; then', result.stdout)
            self.assertIn("phosh-profile.env", result.stdout)
            self.assertIn("phosh-integration-contract", result.stdout)
            self.assertIn("app-handler-v1-launch-switcher-dbus-home", result.stdout)
            self.assertIn("mobile Phosh", result.stdout)
            self.assertIn("atomos-overview-chat-submit", result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS:-0}"', result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-0}"', result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS:-0}"', result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"', result.stdout)
            self.assertIn("bind_phosh_session_env()", result.stdout)
            self.assertIn("xargs -0 -n1", result.stdout)
            self.assertIn("corrected invalid WAYLAND_DISPLAY to wayland-0", result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS", result.stdout)
            self.assertIn("overview-chat-ui-overlay-contract", result.stdout)
            self.assertIn("overview-chat-ui-overlay-v6-autostart-restored", result.stdout)
            self.assertNotIn("atomos-mobile-lockscreen --lock", result.stdout)
            self.assertNotIn("atomos-lock-daemon.desktop", result.stdout)
            self.assertNotIn("atomos-lock-daemon.service", result.stdout)
            # Regression guard: commit d6405345 "fix: home screen" deleted both
            # the XDG autostart for atomos-overview-chat-ui AND the vendor
            # phosh patches that spawned it on home unfold, leaving the chat
            # UI with nothing to launch it on the home screen. The overlay
            # must write a .desktop that runs the launcher with --start (Phosh drives --show).
            self.assertIn("/etc/xdg/autostart/atomos-overview-chat-ui.desktop", result.stdout)
            self.assertIn("Exec=/usr/libexec/atomos-overview-chat-ui --start", result.stdout)
            self.assertIn("OnlyShowIn=GNOME;Phosh;", result.stdout)
            self.assertNotIn(
                "rm -f /etc/xdg/autostart/atomos-overview-chat-ui.desktop\n'",
                result.stdout,
                "apply-overlay.sh must not unconditionally remove the chat UI autostart "
                "(see commit d6405345 'fix: home screen' regression).",
            )

    def test_apply_overlay_dump_mode_replaces_lock_placeholder_disabled(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text('PMOS_LOCK_PARITY="0"\n', encoding="utf-8")
            result = run_script(
                S_ROOTFS / "apply-overlay.sh",
                profile,
                env={"ATOMOS_OVERLAY_DUMP_ONLY": "1", "ATOMOS_LOCK_PARITY": "0"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn('if [ "0" = "1" ]; then', result.stdout)

    def test_validate_lock_parity_dump_mode_generates_expected_checks(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text(
                "\n".join(
                    [
                        'PROFILE_NAME="test"',
                        'PMOS_LOCK_PARITY="1"',
                        'PMOS_UI="phosh"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            result = run_script(
                S_VALIDATE / "validate-lock-parity.sh",
                profile,
                env={"ATOMOS_VALIDATE_DUMP_ONLY": "1", "ATOMOS_LOCK_PARITY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn('if [ "1" = "1" ]; then', result.stdout)
            self.assertIn("phosh-profile.env", result.stdout)
            self.assertIn("gargantua-black.jpg", result.stdout)
            self.assertIn("check_cmd phosh", result.stdout)
            self.assertIn("51-atomos-phosh-favorites.conf", result.stdout)
            self.assertNotIn("atomos-lock-daemon.service", result.stdout)
            self.assertNotIn("atomos-lock-daemon.desktop", result.stdout)

    def test_validate_dump_skips_phosh_favorites_when_disabled(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text(
                "\n".join(
                    [
                        'PROFILE_NAME="test"',
                        'PMOS_LOCK_PARITY="1"',
                        'PMOS_UI="phosh"',
                        'PMOS_CLEAR_PHOSH_FAVOURITES="0"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            result = run_script(
                S_VALIDATE / "validate-lock-parity.sh",
                profile,
                env={"ATOMOS_VALIDATE_DUMP_ONLY": "1", "ATOMOS_LOCK_PARITY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertNotIn("51-atomos-phosh-favorites", result.stdout)

    def test_wallpaper_dconf_dump_contains_keys(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text('PROFILE_NAME="test"\nPMOS_DEVICE="fairphone-fp4"\n', encoding="utf-8")
            result = run_script(
                S_ROOTFS / "apply-atomos-wallpaper-dconf.sh",
                profile,
                env={"ATOMOS_WALLPAPER_DCONF_DUMP_ONLY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("dbus-run-session", result.stdout)
            self.assertIn("atomos-wallpaper-dconf: apk add dbus glib gsettings-desktop-schemas", result.stdout)
            self.assertIn("gsettings set org.gnome.desktop.background picture-uri", result.stdout)
            self.assertIn("picture-uri-dark", result.stdout)
            self.assertIn("gsettings set org.gnome.desktop.background primary-color", result.stdout)
            self.assertIn("picture-options none", result.stdout)
            self.assertIn("org.gnome.desktop.screensaver", result.stdout)
            self.assertIn("gsettings set org.gnome.desktop.screensaver picture-uri", result.stdout)
            self.assertIn("50-atomos-wallpaper.conf", result.stdout)
            self.assertIn("locks/50-atomos-wallpaper", result.stdout)
            self.assertIn("dconf update", result.stdout)
            self.assertIn("org.gnome.desktop.session idle-delay", result.stdout)
            self.assertIn("org.gnome.desktop.screensaver lock-enabled true", result.stdout)
            self.assertIn("org.gnome.desktop.screensaver lock-delay", result.stdout)
            self.assertIn("getent passwd 10000", result.stdout)

    def test_phosh_dconf_dump_contains_favorites(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text(
                'PROFILE_NAME="test"\nPMOS_DEVICE="fairphone-fp4"\n',
                encoding="utf-8",
            )
            result = run_script(
                S_PHOSH / "apply-atomos-phosh-dconf.sh",
                profile,
                env={"ATOMOS_PHOSH_DCONF_DUMP_ONLY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("51-atomos-phosh-favorites.conf", result.stdout)
            self.assertIn("sm/puri/phosh", result.stdout)
            self.assertIn("favorites=@as []", result.stdout)


class TestDockerfileToolchain(unittest.TestCase):
    """Static checks on the Dockerfile to prevent cross-compilation regressions."""

    def test_dockerfile_has_cross_linker(self):
        """A cross-linker capable of aarch64 ELF output must be available."""
        content = (ISO_ROOT / "docker" / "pmbootstrap.Dockerfile").read_text()
        self.assertTrue(
            "aarch64-linux-gnu-gcc" in content or "aarch64-linux-musl-gcc" in content,
            "Dockerfile must configure an aarch64 cross-linker (gnu-gcc or musl-gcc)",
        )

    def test_dockerfile_configures_cargo_linker(self):
        """Cargo must be told which linker to use for aarch64-unknown-linux-musl."""
        content = (ISO_ROOT / "docker" / "pmbootstrap.Dockerfile").read_text()
        self.assertIn("config.toml", content,
            "Dockerfile must write a cargo config.toml for the cross-linker")
        self.assertIn("aarch64-unknown-linux-musl", content,
            "Cargo config must reference the musl target")

    def test_dockerfile_has_rustup_target(self):
        """The aarch64-unknown-linux-musl rustup target must be added."""
        content = (ISO_ROOT / "docker" / "pmbootstrap.Dockerfile").read_text()
        self.assertIn("rustup target add aarch64-unknown-linux-musl", content,
            "Dockerfile must add the aarch64 musl rustup target")


class TestPhoshHomeAndPanelSourceContracts(unittest.TestCase):
    def test_home_enables_phoc_edge_drag_without_reserved_strip(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn('"drag-mode", PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE', text)
        self.assertIn('"exclusive-zone", 0', text)
        self.assertIn('"exclusive", 0', text)
        self.assertIn("#define PHOSH_HOME_DRAG_THRESHOLD 0.0", text)
        self.assertIn("phosh_overview_has_running_activities", text)
        self.assertIn("ATOMOS_APP_HANDLER_LAUNCHER_PATH", text)
        self.assertIn("atomos_phosh_sync_app_handler_lifecycle", text)
        self.assertIn("atomos_phosh_bottom_edge_drag_disabled", text)
        self.assertIn("ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG_ENV", text)
        import sys

        tests_dir = pathlib.Path(__file__).resolve().parent
        if str(tests_dir) not in sys.path:
            sys.path.insert(0, str(tests_dir))
        from phosh_home_c_lifecycle import (
            assert_phosh_home_c_shell_lifecycle_contract,
            extract_c_function,
        )

        lifecycle_fn = extract_c_function(text, "atomos_phosh_sync_app_handler_lifecycle")
        assert_phosh_home_c_shell_lifecycle_contract(lifecycle_fn)
        self.assertIn('action = "--hide"', text)
        self.assertIn("atomos_phosh_sync_home_bg_layer", text)
        self.assertIn('layer = "top"', text)
        self.assertIn('layer = "bottom"', text)
        # Vendor parity: mouse click on the home bar toggles fold/unfold.
        self.assertIn("phosh_home_set_state (self, !self->state);", text)

    def test_home_app_grid_toggle_hidden_when_handler_active(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn("app_grid_toggle_button", text)
        self.assertIn(
            "gtk_widget_set_visible (self->app_grid_toggle_button, FALSE);",
            text,
            msg="Phosh dock toggle must be hidden; Rust handler owns launcher UI",
        )

    def test_home_syncs_app_handler_lifecycle_from_state_transitions(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn(
            "atomos_phosh_sync_app_handler_lifecycle (self->state);",
            text,
            msg="home.c must sync app-handler lifecycle from drag/home state transitions",
        )
        self.assertNotIn("atomos_phosh_sync_app_switcher_lifecycle", text)

    def test_home_syncs_overview_chat_ui_lifecycle_from_state_transitions(self):
        # Regression guard: commit d6405345 "fix: home screen" deleted both
        #   vendor/phosh/patches/0003-atomos-overview-chat-ui-lifecycle.patch
        #   vendor/phosh/patches/0004-atomos-overview-chat-ui-show-on-unfold.patch
        # which used to spawn /usr/libexec/atomos-overview-chat-ui --show /
        # --hide on home fold/unfold. The replacement lives in home.c as
        # atomos_phosh_sync_overview_chat_ui_lifecycle() and must be called
        # from on_drag_state_changed alongside the other two sync helpers,
        # or the layer-shell chat UI never appears on the home screen.
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn(
            "ATOMOS_OVERVIEW_CHAT_UI_LAUNCHER_PATH",
            text,
            msg="home.c must define the /usr/libexec/atomos-overview-chat-ui launcher path",
        )
        self.assertIn(
            '"/usr/libexec/atomos-overview-chat-ui"',
            text,
            msg="home.c must reference the canonical launcher path string",
        )
        self.assertIn(
            "atomos_phosh_sync_overview_chat_ui_lifecycle",
            text,
            msg="home.c must define the overview chat UI lifecycle sync helper",
        )
        self.assertTrue(
            "atomos_phosh_sync_overview_chat_ui_lifecycle (self->state);" in text or
            "atomos_phosh_chat_ui_layer_state_for_home" in text,
            msg=(
                "home.c must call atomos_phosh_sync_overview_chat_ui_lifecycle "
                "from on_drag_state_changed"
            ),
        )
        self.assertIn(
            "if (self->state != PHOSH_HOME_STATE_TRANSITION)",
            text,
            msg="chat-ui sync must be skipped during drag TRANSITION",
        )
        self.assertIn('layer = "overlay"', text, msg="unfolded home must promote chat-ui to overlay")
        chat_lifecycle = text.split("atomos_phosh_sync_overview_chat_ui_lifecycle", 1)[1].split(
            "atomos_phosh_bottom_edge_drag_disabled", 1
        )[0]
        self.assertNotIn(
            'layer = "top"',
            chat_lifecycle,
            msg="layer=top leaves chat-ui under phosh-home (home-bg may still use top)",
        )
        self.assertIn("phosh_shell_get_locked", text, msg="chat-ui must hide while session locked")
        self.assertIn(
            "g_idle_add (atomos_phosh_sync_overview_chat_ui_after_map_idle",
            text,
            msg="unlock must re-sync chat-ui layer from drag state",
        )
        self.assertIn(
            "atomos_phosh_sync_overview_chat_ui_lifecycle (PHOSH_HOME_STATE_UNFOLDED)",
            text,
            msg="unfold stable gate must promote chat-ui to overlay",
        )
        self.assertIn(
            "ATOMOS_OVERVIEW_CHAT_UI_DISABLE_LIFECYCLE_ENV",
            text,
            msg="lifecycle helper must expose a kill-switch env for bisection",
        )
        self.assertIn(
            "ATOMOS_OVERVIEW_CHAT_UI_LAYER=%s %s --show",
            text,
            msg="overview chat lifecycle must pass layer on --show like home-bg",
        )

    def test_overview_force_hides_running_activities_at_init(self):
        text = PHOSH_OVERVIEW_C.read_text(encoding="utf-8")
        self.assertIn(
            "phosh_overview_set_running_activities_visible (self, FALSE);",
            text,
            msg="overview must force-hide the Phosh activity carousel at init",
        )

    def test_overview_exposes_running_activities_visible_accessor(self):
        # The surgical accessor home.c relies on must exist with a
        # force-hide flag in private state so set_has_activities cannot
        # un-hide the carousel when a new toplevel maps underneath.
        overview_c = PHOSH_OVERVIEW_C.read_text(encoding="utf-8")
        overview_h = PHOSH_OVERVIEW_C.with_name("overview.h").read_text(encoding="utf-8")
        self.assertIn(
            "phosh_overview_set_running_activities_visible",
            overview_h,
            msg="overview.h must declare the AtomOS surgical visibility accessor",
        )
        self.assertIn(
            "phosh_overview_set_running_activities_visible",
            overview_c,
            msg="overview.c must implement the AtomOS surgical visibility accessor",
        )
        self.assertIn(
            "force_running_activities_hidden",
            overview_c,
            msg="overview.c must carry a force-hide flag so set_has_activities cannot re-show the carousel underneath the rust overlay",
        )

    def test_home_fold_cb_always_folds_for_switcher(self):
        # Vendor parity: fold_cb must always fold the home when the overview
        # emits activity-launched/raised so the switcher actually switches.
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertNotIn("ignoring fold callback while app-grid is opening/visible", text)
        self.assertIn(
            "switcher: tapping an activity card must dismiss the overview",
            text,
        )

    def test_top_panel_enables_phoc_edge_drag(self):
        text = PHOSH_TOP_PANEL_C.read_text(encoding="utf-8")
        self.assertIn("PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE", text)
        self.assertIn('"drag-mode", PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE', text)


class TestAppHandlerScripts(unittest.TestCase):
    def test_app_handler_script_syntax(self):
        for script in (
            S_APP_HANDLER / "build-app-handler.sh",
            S_APP_HANDLER / "install-app-handler.sh",
            S_APP_HANDLER / "hotfix-app-handler.sh",
            S_APP_HANDLER / "preview-app-handler.sh",
            S_APP_HANDLER / "preview-app-handler-egui.sh",
            S_APP_HANDLER / "test-app-handler-local.sh",
            S_APP_HANDLER / "smoke-post-unlock.sh",
            S_APP_HANDLER / "diagnose-session-boot-loop.sh",
            S_APP_HANDLER / "_lib-post-unlock-runtime-checks.remote.sh",
            S_PHOSH / "verify-vendor-phosh-build.sh",
            S_PHOSH / "test-phosh-home-dbus-compile.sh",
        ):
            r = subprocess.run(
                ["bash", "-n", str(script)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, msg=f"{script}: {r.stderr}")

    def test_install_app_handler_contract(self):
        text = (S_APP_HANDLER / "install-app-handler.sh").read_text(encoding="utf-8")
        self.assertIn("ROOTFS_DIR", text)
        self.assertIn("atomos-app-handler.desktop", text)
        self.assertIn("ATOMOS_APP_HANDLER_ENABLE_RUNTIME", text)
        self.assertIn("Exec=/usr/libexec/atomos-app-handler --start", text)
        self.assertIn("app-handler-contract", text)
        self.assertIn("ATOMOS_APP_HANDLER_INSTALL_AUTOSTART:-1", text)
        self.assertIn("launch)", text, msg="libexec launcher must forward launch subcommand")

    def test_install_app_handler_writes_lifecycle_contract_marker(self):
        text = (S_APP_HANDLER / "install-app-handler.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_stack_integration_contracts_in_root", text)
        self.assertIn("/etc/atomos/app-handler-contract", text)
        self.assertIn("/etc/atomos/phosh-integration-contract", text)
        self.assertIn(
            "app-handler-v1-launch-switcher-dbus-home",
            text,
        )
        self.assertRegex(
            text,
            r"install_into_root\(\)[\s\S]*?ensure_app_handler_contract_in_root \"\$root\"",
        )
        self.assertIn("ENSURE_LIFECYCLE_CONTRACT_CMD=", text)
        self.assertIn("APP_HANDLER_CONTRACT_VERSION", text)

    def test_install_app_handler_launcher_signals_on_show_hide(self):
        text = (S_APP_HANDLER / "install-app-handler.sh").read_text(encoding="utf-8")
        self.assertIn("signal_show()", text)
        self.assertIn("signal_hide()", text)
        self.assertIn("kill -USR1", text)
        self.assertIn("kill -USR2", text)
        self.assertIn("action=show", text)
        self.assertIn("action=hide", text)

    def test_qemu_and_fairphone4_final_verify_check_lifecycle_contract(self):
        # If lifecycle integration breaks, builds must fail instead of
        # silently shipping either a swipe-less image (no autostart) or
        # an autostart-only image that ignores phosh's lifecycle hooks.
        for path in (
            SCRIPTS / "build-qemu.sh",
            SCRIPTS / "build-fairphone4.sh",
            SCRIPTS / "build-fairphone4-v2.sh",
            SCRIPTS / "_lib-verify.sh",
        ):
            text = path.read_text(encoding="utf-8")
            self.assertIn(
                "app-handler-v1-launch-switcher-dbus-home",
                text,
                msg=f"{path} must check app-handler lifecycle contract marker in final verify",
            )
            self.assertIn(
                "signal_show",
                text,
                msg=f"{path} must assert the --show signal bridge is wired",
            )
            self.assertIn(
                "signal_hide",
                text,
                msg=f"{path} must assert the --hide signal bridge is wired",
            )
            self.assertIn(
                "atomos-app-handler.desktop",
                text,
                msg=f"{path} must assert the handle-bar autostart desktop is shipped",
            )

    def test_fp4_v2_rootfs_keeps_nftables_off_for_developer_ssh(self):
        """USB gadget SSH must not be blocked by postmarketos-config-nftables drop rules."""
        init = (SCRIPTS / "_lib-rootfs-init.sh").read_text(encoding="utf-8")
        verify = (SCRIPTS / "_lib-verify.sh").read_text(encoding="utf-8")
        overlays = (SCRIPTS / "_lib-rootfs-overlays.sh").read_text(encoding="utf-8")
        qemu = (SCRIPTS / "build-qemu.sh").read_text(encoding="utf-8")
        self.assertIn("ATOMOS_ENABLE_NFTABLES", init)
        self.assertIn("rm -f /target/etc/runlevels/default/nftables", init)
        self.assertIn("99_drop_log.nft", init)
        self.assertIn("55_atomos_developer_usb.nft", init)
        self.assertIn("nftables not in runlevel", verify)
        self.assertIn("rm -f /target/etc/runlevels/default/nftables", overlays)
        self.assertIn("runlevels/boot/sshd", qemu)
        self.assertIn("nftables not in runlevel", qemu)

    def test_image_builds_share_meson_source_tree_skip_helper(self):
        meson_body = (SCRIPTS / "_lib-meson-cache-body.sh").read_text(encoding="utf-8")
        self.assertIn("atomos_tree_content_hash", meson_body)
        self.assertIn("atomos_meson_ninja_build_install", meson_body)
        self.assertIn("unchanged source tree, skipping compile", meson_body)
        for path in (
            SCRIPTS / "build-qemu.sh",
            SCRIPTS / "_lib-build-container-body.sh",
        ):
            text = path.read_text(encoding="utf-8")
            self.assertIn("_lib-meson-cache-body.sh", text, msg=path.name)
            self.assertIn("atomos_meson_ninja_build_install", text, msg=path.name)

    def test_app_handler_handle_paint_uses_core_layout(self):
        core_text = R_APP_HANDLER_HANDLE_CORE.read_text(encoding="utf-8")
        gtk_text = R_APP_HANDLER_HANDLE_RS.read_text(encoding="utf-8")
        lib_text = R_APP_HANDLER_CORE_LIB.read_text(encoding="utf-8")
        egui_text = (
            ISO_ROOT
            / "rust"
            / "atomos-app-handler"
            / "app-egui"
            / "src"
            / "main.rs"
        ).read_text(encoding="utf-8")

        self.assertIn("mod handle", lib_text)
        self.assertIn("mod launch", lib_text)
        self.assertIn("mod session", lib_text)
        self.assertIn("app-handler-v1-launch-switcher-dbus-home", lib_text)
        self.assertIn("PHOSH_INTEGRATION_CONTRACT_BASENAME", lib_text)
        self.assertIn("STACK_INTEGRATION_VERSION", lib_text)
        self.assertIn("PILL_WIDTH_PX", core_text)
        self.assertIn("150.0", core_text)
        self.assertIn("layout_handle_paint", core_text)
        self.assertIn("STRIP_SCRIM", core_text)
        self.assertIn("PILL_FILL", core_text)
        self.assertIn("atomos_app_handler::handle", gtk_text)
        self.assertIn("layout_handle_paint", gtk_text)
        self.assertNotIn("background: transparent", gtk_text)
        self.assertIn("handle::layout_handle_paint", egui_text)
        self.assertIn("handle::STRIP_SCRIM", egui_text)
        self.assertIn("handle::PILL_FILL", egui_text)

    def test_app_handler_local_test_script_runs_core_and_egui(self):
        text = (S_APP_HANDLER / "test-app-handler-local.sh").read_text(encoding="utf-8")
        self.assertIn("cargo test -p atomos-app-handler", text)
        self.assertIn("cargo test -p atomos-app-handler-egui", text)
        self.assertIn("handle_paint", text)
        self.assertIn("home_handler_contract", text)
        self.assertIn("test-phosh-home-dbus-compile.sh", text)

    def test_phosh_home_dbus_wired_for_handler_fold_ipc(self):
        dbus_c = PHOSH_ATOMOS_HOME_DBUS_C.read_text(encoding="utf-8")
        dbus_xml = PHOSH_ATOMOS_HOME_DBUS_XML.read_text(encoding="utf-8")
        shell_c = PHOSH_SHELL_C.read_text(encoding="utf-8")
        self.assertIn("SetFolded", dbus_xml)
        self.assertIn("SetUnfolded", dbus_xml)
        self.assertIn("handle_set_folded", dbus_c)
        self.assertIn("handle_set_unfolded", dbus_c)
        self.assertIn("phosh_home_set_state", dbus_c)
        self.assertIn("atomos_phosh_home_dbus", shell_c)
        self.assertIn("phosh_atomos_phosh_home_dbus_set_exported", shell_c)

    def test_core_session_policy_matches_phosh_home_lifecycle(self):
        """Rust core is the contract; Phosh C must not drift (e.g. --show on unfold)."""
        session_rs = (
            ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "session.rs"
        ).read_text(encoding="utf-8")
        home_c = PHOSH_HOME_C.read_text(encoding="utf-8")
        integration = (
            ISO_ROOT
            / "rust"
            / "atomos-app-handler"
            / "core"
            / "tests"
            / "home_handler_contract.rs"
        ).read_text(encoding="utf-8")

        self.assertIn("shell_lifecycle_action_for_home_state", session_rs)
        self.assertIn("launcher_home_ipc_when_visibility_changes", session_rs)
        self.assertIn("phosh_unfold_must_not_hide_or_show_switcher_via_shell_lifecycle", session_rs)
        self.assertIn("launcher_close_must_not_fold_home", session_rs)
        self.assertIn("after_unlock_home_unfold_does_not_trigger_show_or_hide_shell_sync", integration)
        self.assertIn("launcher_open_close_ipc_contract", integration)

        import sys

        tests_dir = pathlib.Path(__file__).resolve().parent
        if str(tests_dir) not in sys.path:
            sys.path.insert(0, str(tests_dir))
        from phosh_home_c_lifecycle import (
            assert_phosh_home_c_shell_lifecycle_contract,
            extract_c_function,
        )

        lifecycle_fn = extract_c_function(home_c, "atomos_phosh_sync_app_handler_lifecycle")
        assert_phosh_home_c_shell_lifecycle_contract(lifecycle_fn)
        self.assertIn('action = "--hide"', home_c)
        self.assertIn("Do NOT --show on unfold", home_c)

    def test_shell_no_longer_auto_folds_on_toplevel_count(self):
        text = PHOSH_SHELL_C.read_text(encoding="utf-8")
        self.assertIn(
            "fold/unfold is driven by rust atomos-app-handler",
            text,
        )
        self.assertNotRegex(
            text,
            r"on_toplevel_added[\s\S]{0,400}phosh_home_set_state \(PHOSH_HOME \(priv->home\), PHOSH_HOME_STATE_FOLDED\)",
        )

    def test_app_grid_button_launches_via_handler_not_tracker(self):
        text = PHOSH_APP_GRID_BUTTON_C.read_text(encoding="utf-8")
        self.assertIn("/usr/libexec/atomos-app-handler launch", text)
        self.assertNotRegex(
            text,
            r"phosh_app_tracker_launch_app_info\s*\(",
            msg="activate_cb must not call phosh_app_tracker_launch_app_info",
        )


class TestCheckoutPhoshScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "checkout-phosh.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_supports_phosh_ref_pin(self):
        text = (S_PHOSH / "checkout-phosh.sh").read_text(encoding="utf-8")
        self.assertIn("ATOMOS_PHOSH_GIT_REF", text)
        self.assertIn("rust/phosh/phosh", text)
        self.assertIn("Using pinned Phosh ref", text)


class TestResetWorkdirScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PMB / "reset-workdir.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_no_regex_match_on_work_dir(self):
        """Regression: awk '$5 ~ ("^" root ...)' treats '.' in root as regex any-char."""
        src = (ISO_ROOT / "scripts" / "pmb" / "reset-workdir.sh").read_text(encoding="utf-8")
        self.assertNotIn('$5 ~ ("^" root', src)
        self.assertIn("findmnt", src)
        self.assertIn("virtiofs", src)
        self.assertIn("ATOMOS_RESET_WORKDIR_UMOUNT", src)


class TestBuildAtomosPhoshScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "build-atomos-phosh-pmbootstrap.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_drops_virtual_gnome_settings_daemon_dep(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_phosh_apkbuild_no_virtual_gsd_dep", text)
        self.assertIn('dep != "gnome-settings-daemon"', text)

    def test_resets_native_tmp_source_override_state(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_tmp_for_src_override", text)
        self.assertIn("/tmp/pmbootstrap-local-source-copy", text)
        self.assertIn("/tmp/src-pkgname", text)

    def test_resets_native_ccache_permissions(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_ccache_dir", text)
        self.assertIn("/home/pmos/.ccache/tmp", text)
        self.assertIn("ATOMOS_PHOSH_DISABLE_CCACHE", text)
        self.assertIn("CCACHE_DISABLE=1", text)

    def test_resets_native_user_cache_permissions(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_user_cache_dir", text)
        self.assertIn("/home/pmos/.cache", text)
        self.assertIn("g-ir-scanner", text)

    def test_resets_native_abuild_key_permissions(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_abuild_key_permissions", text)
        self.assertIn("/home/pmos/.abuild", text)
        self.assertIn("chmod 600", text)
        self.assertIn("Regenerating unreadable abuild private key", text)
        self.assertIn("abuild-keygen -a -n", text)
        self.assertIn("install -m 644", text)
        self.assertIn("prepare_host_apk_keyring_from_native", text)
        self.assertIn("config_apk_keys", text)

    def test_resets_native_package_output_permissions(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_package_output_permissions", text)
        self.assertIn("/home/pmos/packages/pmos/${ARCH}", text)
        self.assertIn("/home/pmos/packages/edge/${ARCH}", text)
        self.assertIn("chown -R pmos:pmos /home/pmos/packages", text)
        self.assertIn("chmod -R a+rwX /home/pmos/packages", text)
        self.assertIn("prepare_native_abuild_repo_destination", text)
        self.assertIn("removed stale REPODEST= override from abuild.conf", text)
        self.assertIn("prepare_host_package_output_permissions", text)
        self.assertIn('pmos_root="${pkg_root}/pmos"', text)
        self.assertIn("prepare_host_local_repo_aliases", text)
        self.assertIn("Aliased local package repo path: pmos/${ARCH} -> edge/${ARCH}", text)
        self.assertIn("ABUILD_ENV=()", text)
        self.assertIn("recover_edge_repo_from_pmos_on_missing_artifact", text)
        self.assertIn("recover_edge_repo_from_any_local_phosh_artifacts", text)
        self.assertIn("Package not found after build", text)
        self.assertIn("Recovered missing edge artifact", text)
        self.assertIn("Recovered edge artifact from local buckets", text)
        self.assertIn("PMB_WORK_OVERRIDE", text)

    def test_prefers_non_temp_phosh_apkbuild_before_temp(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("for d in main community testing temp; do", text)
        self.assertIn("A stale temp/phosh from older", text)

    def test_aligns_phosh_pkgver_with_source_meson_version(self):
        text = (S_PHOSH / "build-atomos-phosh-pmbootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_phosh_apkbuild_pkgver_matches_source", text)
        self.assertIn("version:\\s*'([^']+)'", text)
        self.assertIn("pkgver=", text)


class TestPreviewPhoshGtkContainerScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "preview-phosh-gtk-container.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_defaults_to_egui_preview(self):
        text = (S_PHOSH / "preview-phosh-gtk-container.sh").read_text(encoding="utf-8")
        self.assertIn("preview-overview-chat-ui-egui.sh", text)
        self.assertIn("--container-x11", text)
        self.assertIn("ATOMOS_PREVIEW_CONTAINER_IMAGE", text)

    def test_visual_preview_script_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "preview-phosh-home-chat-ui-visual.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)


class TestBuildOverviewChatUiScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "build-overview-chat-ui.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_builds_app_package(self):
        text = (S_OVERVIEW / "build-overview-chat-ui.sh").read_text(encoding="utf-8")
        self.assertIn("atomos-overview-chat-ui-app", text)
        self.assertNotIn("--features", text)
        self.assertIn("resolve_sysroot", text)
        self.assertIn(".atomos-pmbootstrap-work", text)
        self.assertIn("default_overview_linker", text)
        self.assertIn("aarch64-linux-gnu-gcc", text)
        self.assertIn("qemu-aarch64", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ALLOW_APK_UPGRADE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_MUSL_RETRY_WITH_RUST_LLD", text)
        self.assertIn("Retrying overview chat UI build with rust-lld", text)

    def test_cargo_compilation_verification(self):
        import shutil
        if not shutil.which("cargo"):
            self.skipTest("cargo not installed")
        r = subprocess.run(
            ["cargo", "check", "--workspace", "--all-targets"],
            cwd=str(ISO_ROOT / "rust" / "atomos-overview-chat-ui"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            r.returncode,
            0,
            msg=f"Cargo check failed for atomos-overview-chat-ui workspace:\n{r.stderr}\n{r.stdout}",
        )


class TestOverviewChatUiCssSafety(unittest.TestCase):
    """Static CSS checks to prevent target-image startup crashes."""

    def test_style_does_not_use_focus_within(self):
        text = STYLE_RS.read_text(encoding="utf-8")
        self.assertNotIn(
            "scrolledwindow.atomos-chat-input:focus-within",
            text,
            msg="avoid :focus-within in GTK CSS due target parser/runtime crash risk",
        )
        self.assertNotIn(
            "textview.atomos-chat-input:focus-within",
            text,
            msg="avoid :focus-within in GTK CSS due target parser/runtime crash risk",
        )

    def test_input_frame_uses_border_and_not_outline(self):
        import re
        text = STYLE_RS.read_text(encoding="utf-8")
        self.assertIn("scrolledwindow.atomos-chat-input", text)
        self.assertTrue(
            "border: 1px solid alpha(#000000, 0.18);" in text or
            "border: 1px solid #303132;" in text
        )
        # Verify that we don't apply 'outline' styling to the scrolledwindow input frame itself,
        # which can cause rendering bugs on mobile Phosh/GTK stacks. Other elements like top-dock are allowed to use outlines.
        blocks = re.findall(r"([^{}]+)\s*\{([^}]+)\}", text)
        for selector, content in blocks:
            if "scrolledwindow.atomos-chat-input" in selector:
                self.assertNotIn("outline:", content, msg=f"Input frame block '{selector}' must not use outline")


class TestInstallOverviewChatUiScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "install-overview-chat-ui.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_installs_binary_symlink(self):
        text = (S_OVERVIEW / "install-overview-chat-ui.sh").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/atomos-overview-chat-ui", text)
        self.assertIn("/usr/bin/atomos-overview-chat-ui", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL_DEFAULT:-0", text)
        self.assertIn("resolve_runtime_paths", text)
        self.assertIn('candidate="/run/user/$uid"', text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", text)
        self.assertIn("__OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT__", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS", text)
        self.assertIn("__OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT__", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE", text)
        self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE:-0', text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_LAYER", text)
        self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom', text)
        self.assertIn("layer=${ATOMOS_OVERVIEW_CHAT_UI_LAYER", text)
        self.assertIn("    --start)", text)
        self.assertIn("    --show)", text)
        self.assertIn("log_action", text)
        self.assertIn("stop_ui", text)
        self.assertIn("start_ui", text)
        self.assertIn("bind_phosh_session_env_if_missing", text)
        self.assertIn("wait_for_phosh_wayland_env", text)
        self.assertIn("pgrep -u", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", text)
        self.assertIn("atomos-overview-chat-ui.disabled", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY", text)
        self.assertIn("no prebuilt binary found; fail install", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_INSTALL_AUTOSTART", text)
        self.assertIn("/etc/xdg/autostart/atomos-overview-chat-ui.desktop", text)
        self.assertIn("Exec=/usr/libexec/atomos-overview-chat-ui --start", text)
        self.assertNotIn("Exec=/usr/libexec/atomos-overview-chat-ui --show", text)


class TestInstallAtomosHomeBgScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(ISO_ROOT / "scripts" / "home-bg" / "install-atomos-home-bg.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_stop_ui_waits_for_termination_robustly(self):
        text = (ISO_ROOT / "scripts" / "home-bg" / "install-atomos-home-bg.sh").read_text(encoding="utf-8")
        # Ensure our stop_ui helper exists
        self.assertIn("stop_ui()", text)
        # Ensure it collects all associated PIDs to wait for
        self.assertIn("pgrep -f '/usr/local/bin/atomos-home-bg'", text)
        # Ensure it uses a wait loop to wait for them to terminate gracefully
        self.assertIn("while [ $i -lt 10 ]; do", text)
        self.assertIn("sleep 0.1", text)
        # Ensure it has a fallback SIGKILL to force termination if hung
        self.assertIn("kill -9", text)

    def test_cargo_compilation_verification(self):
        import shutil
        if not shutil.which("cargo"):
            self.skipTest("cargo not installed")
        r = subprocess.run(
            ["cargo", "check", "--workspace", "--all-targets"],
            cwd=str(ISO_ROOT / "rust" / "atomos-home-bg"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            r.returncode,
            0,
            msg=f"Cargo check failed for atomos-home-bg workspace:\n{r.stderr}\n{r.stdout}",
        )

    def test_install_home_bg_launcher_session_env_binding(self):
        text = (ISO_ROOT / "scripts" / "home-bg" / "install-atomos-home-bg.sh").read_text(encoding="utf-8")
        self.assertIn("bind_phosh_session_env_if_missing", text)
        self.assertIn("xargs -0", text)
        self.assertIn("corrected invalid WAYLAND_DISPLAY to wayland-0", text)


class TestSmokeChatUiPostUnlockScript(unittest.TestCase):
    def test_bash_syntax(self):
        script = S_OVERVIEW / "smoke-chat-ui-post-unlock.sh"
        r = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_remote_lib_bash_syntax(self):
        lib = S_OVERVIEW / "_lib-chat-ui-smoke.remote.sh"
        r = subprocess.run(["bash", "-n", str(lib)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_smoke_drives_dbus_and_checks_overlay_runtime(self):
        text = (S_OVERVIEW / "_lib-chat-ui-smoke.remote.sh").read_text(encoding="utf-8")
        self.assertIn("SetUnfolded", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay", text)
        self.assertIn("gtk_layer=Overlay", text)
        self.assertIn("atomos_find_chat_ui_binary_pid", text)


class TestOverviewChatUiLifecycleStackRegression(unittest.TestCase):
    """Guards for chat-ui invisible-on-home / visible-on-lock regressions."""

    def test_phosh_home_chat_ui_local_script_expects_overlay_and_lock_gate(self):
        script = S_PHOSH / "test-phosh-home-chat-ui-local.sh"
        text = script.read_text(encoding="utf-8")
        self.assertIn('overview unfold uses chat overlay layer', text)
        self.assertIn("overview chat hides while session locked", text)
        self.assertIn("overview fold demotes chat to bottom layer", text)

    def test_diagnose_script_remote_blob_has_no_single_quotes(self):
        text = (SCRIPTS / "app-handler" / "diagnose-app-handler.sh").read_text(encoding="utf-8")
        start = text.index("REMOTE_SCRIPT='") + len("REMOTE_SCRIPT='")
        end = text.index("\n'\n", start)
        body = text[start:end]
        self.assertNotIn("'", body)
        self.assertIn("layer=overlay", body)

    def test_lib_verify_autostart_start_contract(self):
        text = (SCRIPTS / "_lib-verify.sh").read_text(encoding="utf-8")
        self.assertIn(
            "Exec=/usr/libexec/atomos-overview-chat-ui --start",
            text,
        )


class TestInstallAtomosAgentsScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_ROOTFS / "install-atomos-agents.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_dump_mode_contains_bridge_contract(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text(
                "\n".join(
                    [
                        'PROFILE_NAME="test"',
                        'PMOS_INSTALL_ATOMOS_AGENTS="1"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            result = run_script(
                S_ROOTFS / "install-atomos-agents.sh",
                profile,
                env={"ATOMOS_INSTALL_DUMP_ONLY": "1"},
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("atomos-agents.service", result.stdout)
            self.assertIn("Environment=PORT=50051", result.stdout)
            self.assertIn("/opt/atomos/agents/src/server.py", result.stdout)
            self.assertIn("ExecStart=/usr/local/bin/atomos-agents-run", result.stdout)
            self.assertIn("python3 -m pip install --break-system-packages --target /opt/atomos/agents/.deps", result.stdout)

    def test_build_image_calls_install_agents_step(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("scripts/rootfs/install-atomos-agents.sh", text)

    def test_build_image_verifies_overview_chat_ui_artifacts(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("verify_overview_chat_ui_install", text)
        self.assertIn("test -x /usr/local/bin/atomos-overview-chat-ui", text)
        self.assertIn("test -x /usr/libexec/atomos-overview-chat-submit", text)
        self.assertIn("verify_overview_chat_ui_launcher_contract", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", text)
        self.assertIn("atomos-overview-chat-ui.disabled", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS", text)
        overlay_text = (SCRIPTS / "rootfs/apply-overlay.sh").read_text(encoding="utf-8")
        self.assertIn("overview-chat-ui-overlay-contract", overlay_text)
        self.assertIn("overview-chat-ui-overlay-v6-autostart-restored", overlay_text)
        self.assertIn("delete-native-rootfs-images.sh", text)

    def test_build_image_reasserts_vendor_phosh_and_final_verifies_before_resync(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        # Defensive re-promote of vendor phosh after all apk-mutating
        # customization steps, before apply-overlay + resync.
        self.assertIn("verify_final_rootfs_customizations", text)
        self.assertIn("Re-promote vendor phosh after every apk-mutating", text)
        # Final pre-resync assertion catches silent phosh downgrade (e.g.
        # install-atomos-agents.sh'"'"'s apk upgrade fallback) and missing
        # overview-chat-ui / home-bg binaries.
        self.assertIn("FINAL-VERIFY FAIL", text)
        # Primary vendor-phosh signal: installed pkgver ends in _p<digits>,
        # which abuild stamps only on --src= builds. Stock Alpine edge
        # phosh never has this suffix.
        self.assertIn("pkgver_has_p_suffix", text)
        self.assertIn("_p[0-9]*", text)
        # Secondary signal: atomos-overview-chat-submit marker visible via
        # strings (it'"'"'s a C-level string literal). The other two markers
        # (atomos-home-chat-entry, atomos-apps-toggle) are gresource-embedded
        # and usually hidden by gzip compression inside the ELF, so we
        # mention them as best-effort diagnostics rather than hard
        # requirements.
        self.assertIn("atomos-overview-chat-submit", text)
        self.assertIn("atomos-home-chat-entry", text)
        self.assertIn("atomos-apps-toggle", text)
        self.assertIn("ATOMOS_SKIP_FINAL_VERIFY", text)
        # Must appear after resync message so the hard-fail is plumbed in
        # right before the rsync step that snapshots chroot -> disk image.
        resync_call_idx = text.index("scripts/rootfs/resync-rootfs-to-disk-image.sh")
        final_verify_call_idx = text.rindex("verify_final_rootfs_customizations")
        self.assertLess(final_verify_call_idx, resync_call_idx)

    def test_build_image_stages_vendor_phosh_apks_into_rootfs_chroot(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        # Host-side staging helper that copies the locally-built vendor
        # phosh/phoc/phosh-mobile-settings APK files directly into the
        # rootfs chroot filesystem at /tmp/atomos-vendor-phosh/, bypassing
        # pmbootstrap bind-mount semantics. Required because
        # /mnt/pmbootstrap/packages is NOT reliably mounted inside the
        # rootfs chroot for `pmb chroot -r` invocations on pmbootstrap 3.9.
        self.assertIn("stage_vendor_phosh_apks_into_rootfs_chroot", text)
        self.assertIn("/tmp/atomos-vendor-phosh", text)
        # The promote step must call the staging helper FIRST (so the apks
        # are present in-chroot before `apk add` runs).
        promote_def_idx = text.index("promote_local_vendor_phosh_into_rootfs() {")
        stage_def_idx = text.index("stage_vendor_phosh_apks_into_rootfs_chroot() {")
        self.assertLess(stage_def_idx, promote_def_idx)
        # And the in-chroot searcher must prefer /tmp/atomos-vendor-phosh
        # (the host-staged dir) over the unreliable /mnt/pmbootstrap/packages
        # mount path.
        tmp_search_idx = text.index('"/tmp/atomos-vendor-phosh"')
        mnt_search_idx = text.index('"/mnt/pmbootstrap/packages/edge/${arch}"')
        self.assertLess(tmp_search_idx, mnt_search_idx)
        # phoc must be OPTIONAL: our pmbootstrap `build --src=rust/phosh/phosh`
        # only produces the phosh package family, not the separate phoc
        # package. Making phoc required makes the promote step permanently
        # no-op.  Only phosh_apk is mandatory; the "phoc_apk=<empty>"
        # abort path that used to exist must be gone.
        self.assertNotIn('if [ -z "$phoc_apk" ] || [ -z "$phosh_apk" ]', text)
        self.assertIn('if [ -z "$phosh_apk" ]', text)
        # The staging function must pick up the full phosh subpackage set
        # our build produces (libphosh/phosh-schemas/phosh-systemd/
        # phosh-portalsconf), using the exact build-version match so we
        # avoid dragging in older phosh-*.apk clutter from historical
        # builds.
        for subpkg in (
            "libphosh",
            "phosh-schemas",
            "phosh-systemd",
            "phosh-portalsconf",
        ):
            self.assertIn(subpkg, text)
        # The in-chroot apk add step must promote the WHOLE staged set in
        # one transaction rather than only phoc+phosh.
        self.assertIn("/tmp/atomos-vendor-phosh/*.apk", text)
        self.assertIn("apk add --upgrade --allow-untrusted $stage_apks", text)

    def test_build_image_wires_home_bg_build_and_install(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        # CLI flag + default-on toggle.
        self.assertIn("--without-home-bg", text)
        self.assertIn("--skip-home-bg", text)
        self.assertIn("BUILD_HOME_BG=1", text)
        # Build + install + verify calls, parallel to the overview-chat-ui block.
        self.assertIn("scripts/home-bg/build-atomos-home-bg.sh", text)
        self.assertIn("scripts/home-bg/install-atomos-home-bg.sh", text)
        self.assertIn("verify_home_bg_install", text)
        self.assertIn("test -x /usr/local/bin/atomos-home-bg", text)
        self.assertIn("test -x /usr/libexec/atomos-home-bg", text)
        self.assertIn("test -d /usr/share/atomos-home-bg", text)
        self.assertIn("Skip atomos-home-bg (BUILD_HOME_BG=0)", text)

    def test_makefile_passes_without_home_bg_flag(self):
        text = (ISO_ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("without-home-bg", text)
        self.assertIn("WITHOUT_HOME_BG", text)
        self.assertIn("--without-home-bg", text)

    def test_build_image_defaults_qemu_to_stock_phosh(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("ATOMOS_ENABLE_VENDOR_PHOSH", text)
        self.assertIn("ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1", text)
        self.assertIn("QEMU profile detected; defaulting to stock phosh", text)
        self.assertIn("purge_local_phosh_overrides", text)
        self.assertIn("verify_stock_phosh_origin", text)
        self.assertIn("verify_vendor_phosh_origin", text)
        self.assertIn("/(mnt/pmbootstrap|home/pmos)/packages/", text)
        self.assertIn("apk add --upgrade phosh", text)
        self.assertIn("installed phosh version", text)
        self.assertIn("newest local vendor build", text)
        self.assertIn("gresource extract /usr/libexec/phosh /mobi/phosh/ui/home.ui", text)
        self.assertIn("home_chat_entry", text)
        self.assertIn("atomos_apps_toggle_btn", text)
        self.assertIn("Skip local Phosh fork sync (stock phosh mode)", text)

    def test_build_image_does_not_pin_gnome_settings_daemon_provider(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertNotIn('set-container-provider.sh" "$CFG" "gnome-settings-daemon"', text)
        self.assertNotIn('EXTRA_PACKAGES_EFFECTIVE="${EXTRA_PACKAGES_EFFECTIVE},gnome-settings-daemon', text)
        self.assertIn("clear_legacy_gsd_config_provider", text)
        self.assertIn("Cleared legacy gnome-settings-daemon provider override(s).", text)

    def test_build_image_has_chrony_overwrite_recovery(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("trying to overwrite etc/chrony/chrony\\\\.conf owned by postmarketos-base-ui", text)
        self.assertIn("apk add --no-interactive --force-overwrite chrony-common chrony", text)
        self.assertNotIn("apk upgrade --no-interactive --force-overwrite", text)
        self.assertIn("clear_legacy_gsd_world_entries", text)
        self.assertIn("sync_local_systemd_edge_indexes", text)
        self.assertIn("Synced local APK repositories: pmos -> edge -> systemd-edge", text)
        self.assertIn("prepare_rootfs_systemd_apk_state", text)
        self.assertIn("/var/lib/systemd-apk/installed.units", text)

    def test_build_image_removes_stale_rootfs_chroot(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("removing stale rootfs chroot for clean install", text)
        self.assertIn("chroot_rootfs_${PMOS_DEVICE}", text)
        self.assertIn("sudo rm -rf", text)

    def test_build_image_fixes_native_rootfs_output_permissions(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("prepare_native_rootfs_output_permissions", text)
        self.assertIn("chown -R pmos:pmos /home/pmos/rootfs", text)
        self.assertIn("rm -f /home/pmos/rootfs/*-sparse.img", text)
        self.assertIn("Cannot open output file .*sparse", text)

    def test_build_image_syncs_local_phosh_fork(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("Sync local Phosh fork sources", text)
        self.assertIn("verify_vendor_phosh_source_contract", text)
        self.assertIn("Verify local Phosh fork source tree", text)
        self.assertIn("verify-vendor-phosh-build.sh", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT", text)

    def test_build_image_supports_pmaports_commit_pin(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("PMOS_PMAPORTS_COMMIT", text)
        self.assertIn("pin_pmaports_commit", text)
        self.assertIn("Resetting dirty pmaports cache before pinning commit", text)
        self.assertIn("git -C \"$PMAPORTS_CACHE\" checkout -q \"$commit\"", text)
        self.assertIn("Pinned pmaports cache to commit", text)


class TestPreviewOverviewChatUiScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "preview-overview-chat-ui.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_no_cargo_features(self):
        text = (S_OVERVIEW / "preview-overview-chat-ui.sh").read_text(encoding="utf-8")
        self.assertNotIn("--features", text)
        self.assertIn("atomos-overview-chat-ui-app", text)
        self.assertIn("atomos-overview-chat-ui-egui", text)

    def test_egui_wrapper_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "preview-overview-chat-ui-egui.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_egui_wrapper_no_features(self):
        text = (S_OVERVIEW / "preview-overview-chat-ui-egui.sh").read_text(encoding="utf-8")
        self.assertNotIn("--features", text)
        self.assertIn("atomos-overview-chat-ui-egui", text)

    def test_gtk_osx_setup_wrapper_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "setup-gtk-osx.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_local_test_harness_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "test-overview-chat-ui-local.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_local_test_harness_targets_all_crates(self):
        text = (S_OVERVIEW / "test-overview-chat-ui-local.sh").read_text(encoding="utf-8")
        self.assertIn("atomos-overview-chat-ui", text)
        self.assertIn("atomos-overview-chat-ui-app", text)
        self.assertIn("atomos-overview-chat-ui-egui", text)
        self.assertNotIn("--features", text)


class TestHotfixOverviewChatUiScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_OVERVIEW / "hotfix-overview-chat-ui.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_references_launchers_and_restart_override(self):
        text = (S_OVERVIEW / "hotfix-overview-chat-ui.sh").read_text(encoding="utf-8")
        self.assertIn("atomos-overview-chat-ui-launcher", text)
        self.assertIn("/usr/libexec/atomos-overview-chat-ui", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_RESTART_CMD", text)
        self.assertIn("reject_glibc_linked_binary", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL_DEFAULT:-0", text)
        self.assertIn("resolve_runtime_paths", text)
        self.assertIn('candidate="/run/user/$uid"', text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_LAYER", text)
        self.assertIn("bind_phosh_session_env_if_missing", text)
        self.assertIn("pgrep phosh", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", text)
        self.assertIn("atomos-overview-chat-ui.disabled", text)


class TestEnsurePmbootstrapMirrors(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PMB / "ensure-pmbootstrap-mirrors.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)


class TestSetPmbootstrapOptionScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PMB / "set-pmbootstrap-option.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)


class TestPhoshForkWorkflow(unittest.TestCase):
    def test_checkout_script_uses_local_fork_path(self):
        text = (S_PHOSH / "checkout-phosh.sh").read_text(encoding="utf-8")
        self.assertIn("rust/phosh/phosh", text)
        self.assertIn("ATOMOS_PHOSH_SRC", text)
        self.assertNotIn("reset --hard", text)
        self.assertNotIn("clean -fd", text)
        self.assertNotIn("apply-phosh-atomos-patches.sh", text)

    def test_apply_patch_script_is_deprecated(self):
        text = (S_PHOSH / "apply-phosh-atomos-patches.sh").read_text(encoding="utf-8")
        self.assertIn("deprecated", text)
        self.assertIn("Maintain Phosh directly", text)

    def test_local_phosh_fork_checkout_exists_or_is_ignorable(self):
        path = ISO_ROOT / "vendor" / "phosh" / ".gitignore"
        if not path.exists():
            path = ISO_ROOT / "rust" / "phosh" / ".gitignore"
        gitignore = path.read_text(encoding="utf-8")
        self.assertIn("upstream Phosh", gitignore)


class TestAtomosDeviceScripts(unittest.TestCase):
    def test_bash_syntax(self):
        for name in (
            "atomos-device-ssh.sh",
            "atomos-overview-chat-ui-remote-show.sh",
            "atomos-overview-chat-ui-remote-diag.sh",
            "atomos-overview-chat-ui-remote-fg.sh",
            "atomos-overview-chat-ui-segfault-repro.sh",
            "atomos-phosh-runtime-smoke.sh",
        ):
            r = subprocess.run(
                ["bash", "-n", str(S_DEVICE / name)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, msg=f"{name}: {r.stderr}")

    def test_overview_chat_ui_segfault_repro_contract(self):
        text = (S_DEVICE / "atomos-overview-chat-ui-segfault-repro.sh").read_text(encoding="utf-8")
        self.assertIn("atomos-overview-chat-ui --show", text)
        self.assertIn("atomos-overview-chat-ui --hide", text)
        self.assertIn("coredumpctl list /usr/local/bin/atomos-overview-chat-ui", text)
        self.assertIn("RESULT: FAIL", text)
        self.assertIn("RESULT: PASS", text)


class TestWireCustomApkReposScript(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_ROOTFS / "wire-custom-apk-repos.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_rootfs_appends_repo_url(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            rootfs = tmp / "rootfs"
            rootfs.mkdir()
            (rootfs / "etc").mkdir()
            (rootfs / "etc" / "apk").mkdir()
            (rootfs / "etc" / "apk" / "repositories").write_text(
                "https://existing.example/repo\n", encoding="utf-8"
            )
            profile = tmp / "profile.env"
            profile.write_text(
                'PROFILE_NAME="t"\n'
                'PMOS_CUSTOM_APK_REPO_URLS="https://custom.example/@edge/community"\n',
                encoding="utf-8",
            )
            result = run_script(
                S_ROOTFS / "wire-custom-apk-repos.sh",
                "--rootfs",
                str(rootfs),
                str(profile),
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            text = (rootfs / "etc" / "apk" / "repositories").read_text(encoding="utf-8")
            self.assertIn("https://existing.example/repo", text)
            self.assertIn("https://custom.example/@edge/community", text)


class TestApplyPhoshDconfRootfs(unittest.TestCase):
    def test_bash_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "apply-atomos-phosh-dconf.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_rootfs_writes_favorites_conf(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            rootfs = tmp / "rootfs"
            rootfs.mkdir()
            profile = tmp / "profile.env"
            profile.write_text('PROFILE_NAME="t"\n', encoding="utf-8")
            result = run_script(
                S_PHOSH / "apply-atomos-phosh-dconf.sh",
                "--rootfs",
                str(rootfs),
                str(profile),
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            out = rootfs / "etc" / "dconf" / "db" / "local.d" / "51-atomos-phosh-favorites.conf"
            self.assertTrue(out.is_file(), msg="expected dconf fragment under rootfs")
            self.assertIn("sm/puri/phosh", out.read_text(encoding="utf-8"))

    def test_rootfs_skips_favorites_when_disabled(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            rootfs = tmp / "rootfs"
            rootfs.mkdir()
            profile = tmp / "profile.env"
            profile.write_text(
                'PROFILE_NAME="t"\nPMOS_CLEAR_PHOSH_FAVOURITES="0"\n',
                encoding="utf-8",
            )
            result = run_script(
                S_PHOSH / "apply-atomos-phosh-dconf.sh",
                "--rootfs",
                str(rootfs),
                str(profile),
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            out = rootfs / "etc" / "dconf" / "db" / "local.d" / "51-atomos-phosh-favorites.conf"
            self.assertFalse(out.exists())


class TestWallpaperAsset(unittest.TestCase):
    def test_bundled_wallpaper_exists(self):
        bundled = ISO_ROOT / "data" / "wallpapers" / "gargantua-black.jpg"
        self.assertTrue(
            bundled.is_file(),
            msg="expected vendored wallpaper at iso-postmarketos/data/wallpapers/gargantua-black.jpg",
        )

    def test_build_script_references_wallpaper_paths(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("gargantua-black.jpg", text)
        self.assertTrue(
            "../iso-ubuntu/data/wallpapers/gargantua-black.jpg" in text
            or "data/wallpapers/gargantua-black.jpg" in text
        )


class TestProfileRuntimePackages(unittest.TestCase):
    def test_arm64_virt_has_runtime_diag_and_audio_packages(self):
        text = (ISO_ROOT / "config" / "arm64-virt.env").read_text(encoding="utf-8")
        self.assertIn("pipewire-pulse", text)
        self.assertIn("ripgrep", text)
        self.assertIn("PMOS_PMAPORTS_COMMIT", text)

    def test_fairphone_fp4_has_runtime_diag_and_audio_packages(self):
        text = (ISO_ROOT / "config" / "fairphone-fp4.env").read_text(encoding="utf-8")
        self.assertIn("pipewire-pulse", text)
        self.assertIn("ripgrep", text)
        self.assertIn("PMOS_PMAPORTS_COMMIT", text)


if __name__ == "__main__":
    unittest.main()
