#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import glob
import os
import stat

expected_directories = [
    "cross",
    "device/archived",
    "device/community",
    "device/downstream",
    "device/main",
    "device/testing",
    "extra-repos/systemd",
    "main",
    "modem",
    "non-free",
    "sxmo",
    "temp",
]


# pmbootstrap allows placing APKBUILDs in arbitrarily nested directories.
# This test makes sure all of them are in one of the expected locations.
def test_directories():
    apkbuilds = set(glob.iglob("**/APKBUILD", recursive=True))
    expected = set(f for d in expected_directories for f in glob.iglob(d + "/*/APKBUILD"))
    assert apkbuilds == expected, "Found APKBUILD in unexpected directory. " \
        "Note that we moved firmware/* to device/{main,community,testing}/*."


# Ensure no file in pmaports are executable.
# see https://gitlab.postmarketos.org/postmarketOS/pmaports/-/issues/593.
def test_executable_files():
    for file in glob.iglob("[!temp]**/**/*", recursive=True):
        if os.path.isdir(file) or os.path.islink(file):
            continue
            # still check other less common inode types
        permissions = os.stat(file).st_mode
        executable_bits = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        if permissions & executable_bits != 0:
            raise RuntimeError(f"\"{file}\" is executable. Files in pmaports" +
                               " should not be executables. post-* files" +
                               " don't need to be executable and executables" +
                               " should be installed using `install -D" +
                               "m0755` or a variation thereof.")


# Make sure files belong to a package (below a directory with APKBUILD)
def test_files_belong_to_package():
    # Walk directories and set package_dir when we find an APKBUILD
    # This allows matching files in subdirectories to the package directory.
    package_dir = None
    for dirpath, dirs, files in os.walk("."):
        # Skip "hidden" directories (.ci/, device/.shared-patches/)
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        # Ignore files in root directory (README.md)
        if dirpath == '.':
            continue
        # Ignore files under docs/
        if dirpath.startswith('./docs'):
            continue

        # Switched to another directory?
        if package_dir and not dirpath.startswith(package_dir + os.sep):
            package_dir = None

        if 'APKBUILD' in files:
            assert not package_dir, f"Nested packages: {package_dir} and {dirpath} " \
                "both contain an APKBUILD"
            package_dir = dirpath

        # Skip specific ".gitlab-ci.yml" files outside of usual structure
        if dirpath in ["./cross"]:
            files[:] = [f for f in files if f != ".gitlab-ci.yml"]

        assert not files or package_dir, "Found files that do not belong to any package: " \
            f"{dirpath}/{files}"
