"""Gates for Phosh org.atomos.PhoshHome + stack integration contracts."""

import os
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ISO_ROOT = REPO_ROOT / "iso-postmarketos"
S_PHOSH = ISO_ROOT / "scripts" / "phosh"
STACK_VERSION = "app-handler-v1-launch-switcher-dbus-home"


def run_bash(script: pathlib.Path, *args: str, env=None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", str(script), *args],
        check=False,
        text=True,
        capture_output=True,
        env=merged,
    )


class TestPhoshHomeDbusIntegration(unittest.TestCase):
    def test_verify_lib_scripts_exist_and_parse(self):
        for script in (
            S_PHOSH / "_lib-verify-vendor-phosh-atomos.sh",
            S_PHOSH / "verify-vendor-phosh-build.sh",
            S_PHOSH / "test-phosh-home-dbus-compile.sh",
        ):
            r = subprocess.run(
                ["bash", "-n", str(script)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, msg=f"{script}: {r.stderr}")

    def test_verify_vendor_phosh_source_only_passes(self):
        r = run_bash(S_PHOSH / "verify-vendor-phosh-build.sh", "--source-only")
        self.assertEqual(r.returncode, 0, msg=r.stdout + r.stderr)

    def test_dbus_compile_script_source_gate_passes(self):
        r = run_bash(S_PHOSH / "test-phosh-home-dbus-compile.sh")
        self.assertEqual(r.returncode, 0, msg=r.stdout + r.stderr)

    def test_stack_contract_constants_in_rust_core(self):
        lib = (
            ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "lib.rs"
        ).read_text(encoding="utf-8")
        self.assertIn("PHOSH_INTEGRATION_CONTRACT_BASENAME", lib)
        self.assertIn("STACK_INTEGRATION_VERSION", lib)
        self.assertIn(STACK_VERSION, lib)

    def test_apply_overlay_writes_phosh_integration_contract(self):
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            profile = tmp / "profile.env"
            profile.write_text('PMOS_LOCK_PARITY="1"\n', encoding="utf-8")
            r = run_bash(
                ISO_ROOT / "scripts" / "rootfs" / "apply-overlay.sh",
                profile,
                env={"ATOMOS_OVERLAY_DUMP_ONLY": "1", "ATOMOS_LOCK_PARITY": "1"},
            )
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertIn("phosh-integration-contract", r.stdout)
            self.assertIn(STACK_VERSION, r.stdout)

    def test_lib_verify_checks_phosh_integration_contract(self):
        text = (ISO_ROOT / "scripts" / "_lib-verify.sh").read_text(encoding="utf-8")
        self.assertIn("phosh-integration-contract", text)
        self.assertIn("org.atomos.PhoshHome", text)

    def test_build_container_body_verifies_libphosh_after_install(self):
        text = (ISO_ROOT / "scripts" / "_lib-build-container-body.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("atomos_verify_built_libphosh_has_atomos_dbus", text)

    def test_smoke_post_unlock_script_syntax(self):
        script = ISO_ROOT / "scripts" / "app-handler" / "smoke-post-unlock.sh"
        r = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)


if __name__ == "__main__":
    unittest.main()
