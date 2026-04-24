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
S_ROOTFS = SCRIPTS / "rootfs"
S_VALIDATE = SCRIPTS / "validate"
S_DEVICE = SCRIPTS / "device"
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
            self.assertIn("mobile Phosh", result.stdout)
            self.assertIn("atomos-overview-chat-submit", result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS:-1}"', result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-0}"', result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS:-1}"', result.stdout)
            self.assertIn('ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-top}"', result.stdout)
            self.assertIn("bind_phosh_session_env()", result.stdout)
            self.assertIn("xargs -0 -n1", result.stdout)
            self.assertIn("corrected invalid WAYLAND_DISPLAY to wayland-0", result.stdout)
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS", result.stdout)
            self.assertIn("overview-chat-ui-overlay-contract", result.stdout)
            self.assertIn("overview-chat-ui-overlay-v5-lifecycle-only", result.stdout)
            self.assertNotIn("atomos-mobile-lockscreen --lock", result.stdout)
            self.assertNotIn("atomos-lock-daemon.desktop", result.stdout)
            self.assertNotIn("atomos-lock-daemon.service", result.stdout)

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
            self.assertIn("org.gnome.desktop.screensaver", result.stdout)
            self.assertIn("gsettings set org.gnome.desktop.screensaver picture-uri-dark", result.stdout)
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
    def test_home_disables_swipe_drag_and_reserved_divider_strip(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn('"drag-mode", PHOSH_DRAG_SURFACE_DRAG_MODE_NONE', text)
        self.assertIn('"exclusive-zone", 0', text)
        self.assertIn('"exclusive", 0', text)
        self.assertIn("home-bar tap should not toggle fold/unfold", text)

    def test_home_app_grid_toggle_defaults_to_enabled(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn("app_grid_toggle_enabled", text)
        self.assertIn("static gboolean enabled = TRUE;", text)
        self.assertIn('enabled = g_strcmp0 (env, "0") != 0;', text)

    def test_home_ignores_fold_while_app_grid_visible(self):
        text = PHOSH_HOME_C.read_text(encoding="utf-8")
        self.assertIn("ignoring fold callback while app-grid is opening/visible", text)
        self.assertIn("self->app_grid_toggle_queued || gtk_widget_get_visible (GTK_WIDGET (app_grid))", text)

    def test_top_panel_disables_drag_mode(self):
        text = PHOSH_TOP_PANEL_C.read_text(encoding="utf-8")
        self.assertIn("PHOSH_DRAG_SURFACE_DRAG_MODE_NONE", text)
        self.assertIn('"drag-mode", PHOSH_DRAG_SURFACE_DRAG_MODE_NONE', text)


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
        self.assertIn("REPODEST=/home/pmos/packages/edge", text)
        self.assertIn("prepare_host_package_output_permissions", text)
        self.assertIn('pmos_root="${pkg_root}/pmos"', text)
        self.assertIn("prepare_host_local_repo_aliases", text)
        self.assertIn("Aliased local package repo path: pmos/${ARCH} -> edge/${ARCH}", text)
        self.assertIn("ABUILD_ENV=(REPODEST=/home/pmos/packages/edge)", text)
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
        text = STYLE_RS.read_text(encoding="utf-8")
        self.assertIn("scrolledwindow.atomos-chat-input", text)
        self.assertIn("border: 1px solid alpha(#ffffff, 0.22);", text)
        self.assertNotIn("outline: 1px solid alpha(#ffffff, 0.22);", text)


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
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_LAYER", text)
        self.assertIn("bind_phosh_session_env_if_missing", text)
        self.assertIn("pgrep phosh", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", text)
        self.assertIn("atomos-overview-chat-ui.disabled", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY", text)
        self.assertIn("no prebuilt binary found; fail install", text)


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
        self.assertIn("overview-chat-ui-overlay-contract", text)
        self.assertIn("overview-chat-ui-overlay-v5-lifecycle-only", text)
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
        self.assertIn("Synced local APKINDEX files: edge -> systemd-edge", text)
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
        self.assertIn("test -f \"$src_dir/src/home.c\"", text)
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
        gitignore = (ISO_ROOT / "rust" / "phosh" / ".gitignore").read_text(encoding="utf-8")
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
