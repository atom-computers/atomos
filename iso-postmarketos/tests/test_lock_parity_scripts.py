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
            self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME", result.stdout)
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
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS", text)
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
        self.assertIn("delete-native-rootfs-images.sh", text)

    def test_build_image_defaults_qemu_to_stock_phosh(self):
        text = (SCRIPTS / "build-image.sh").read_text(encoding="utf-8")
        self.assertIn("ATOMOS_ENABLE_VENDOR_PHOSH_ON_QEMU", text)
        self.assertIn("ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1", text)
        self.assertIn("QEMU profile detected; defaulting to stock phosh", text)
        self.assertIn("purge_local_phosh_overrides", text)
        self.assertIn("verify_stock_phosh_origin", text)
        self.assertIn("/(mnt/pmbootstrap|home/pmos)/packages/", text)
        self.assertIn("Skip vendor Phosh source sync (stock phosh mode)", text)

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
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", text)
        self.assertIn("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS", text)
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


class TestPhoshAtomosPatches(unittest.TestCase):
    def test_overview_chat_patch_chain_exists(self):
        patch1 = ISO_ROOT / "vendor" / "phosh" / "patches" / "0001-atomos-overview-no-app-grid.patch"
        patch2 = ISO_ROOT / "vendor" / "phosh" / "patches" / "0002-atomos-overview-chat-entry-submit.patch"
        patch3 = ISO_ROOT / "vendor" / "phosh" / "patches" / "0003-atomos-overview-chat-ui-lifecycle.patch"
        patch4 = ISO_ROOT / "vendor" / "phosh" / "patches" / "0004-atomos-overview-chat-ui-show-on-unfold.patch"
        self.assertTrue(patch1.is_file(), msg="expected no-app-grid patch file")
        self.assertTrue(patch2.is_file(), msg="expected chat-entry-submit patch file")
        self.assertTrue(patch3.is_file(), msg="expected chat-ui lifecycle patch file")
        self.assertTrue(patch4.is_file(), msg="expected chat-ui show-on-unfold patch file")

        text1 = patch1.read_text(encoding="utf-8")
        self.assertIn("search_apps", text1)
        self.assertIn("do not surface the app grid", text1)
        self.assertIn("scrolled_window", text1)

        text2 = patch2.read_text(encoding="utf-8")
        self.assertIn("g_spawn_async", text2)
        self.assertIn("atomos-overview-chat-submit", text2)
        self.assertIn("phosh-atomos-chat-entry", text2)

        text3 = patch3.read_text(encoding="utf-8")
        self.assertIn("atomos-overview-chat-ui", text3)
        self.assertIn("--show", text3)
        self.assertIn("--hide", text3)

        text4 = patch4.read_text(encoding="utf-8")
        self.assertIn("on_drag_state_changed", text4)
        self.assertIn("phosh_overview_focus_app_search", text4)

    def test_apply_patch_script_syntax(self):
        r = subprocess.run(
            ["bash", "-n", str(S_PHOSH / "apply-phosh-atomos-patches.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)

    def test_apply_patch_script_supports_selection(self):
        text = (S_PHOSH / "apply-phosh-atomos-patches.sh").read_text(encoding="utf-8")
        self.assertIn("ATOMOS_PHOSH_APPLY_PATCHES", text)
        self.assertIn("ATOMOS_PHOSH_PATCHES", text)
        self.assertIn("patch_is_selected", text)


class TestAtomosDeviceScripts(unittest.TestCase):
    def test_bash_syntax(self):
        for name in (
            "atomos-device-ssh.sh",
            "atomos-overview-chat-ui-remote-show.sh",
            "atomos-overview-chat-ui-remote-diag.sh",
            "atomos-overview-chat-ui-remote-fg.sh",
            "atomos-phosh-runtime-smoke.sh",
        ):
            r = subprocess.run(
                ["bash", "-n", str(S_DEVICE / name)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, msg=f"{name}: {r.stderr}")


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
