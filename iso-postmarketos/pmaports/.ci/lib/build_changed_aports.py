#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
import sys
import os
import pathlib

# Same dir
import common

# pmbootstrap
import pmb.core
import pmb.parse
import pmb.parse._apkbuild
import pmb.helpers.pmaports
from pmb.core.context import get_context


def build_strict(packages, arch):
    common.run_pmbootstrap(["build_init"])
    # We set the timeout to 1 hour because linking the Linux kernel with
    # ThinLTO on our aarch64 runners takes slightly over 30 minutes
    common.run_pmbootstrap(["--details-to-stdout", "--no-ccache",
                            "--timeout", "3600",
                            "build",
                            "--strict", "--force",
                            "--arch", arch, ] + list(packages))


if __name__ == "__main__":
    # Architecture to build for (as in build-{arch})
    if len(sys.argv) != 2:
        print("usage: build_changed_aports.py ARCH")
        sys.exit(1)
    arch = sys.argv[1]

    # Get and print modified packages
    packages = common.get_changed_packages(skip_archived=True)

    # Load context
    sys.argv = ["pmbootstrap.py", "chroot"]
    args = pmb.parse.arguments()
    context = get_context()

    # Get set of all buildable packages for the enabled repos, for skipping unbuildable
    # aports later. We might be given a changed aport from e.g. extra-repos/systemd when
    # that repo is not enabled
    buildable_pkgs = set()
    for path in pmb.core.pkgrepo.pkgrepo_iter_package_dirs():
        buildable_pkgs.add(os.path.basename(path))

    # To store a list of packages from extra-repos/systemd for special handling later:
    systemd_pkgs = list()

    # Filter out packages that either:
    #  1. can't be built for given arch
    #  2. are not found in enabled repos
    # (Iterate over copy of packages, because we modify it in this loop)
    for package in packages.copy():
        if package not in buildable_pkgs:
            print(f"{package}: not in any available repos, skipping")
            packages.remove(package)
            # FIXME: this should probably be more generic, if other repos are added later?
            # This just tosses the package into the list of packages to try building later w/ systemd enabled, and assumes it'll be found there.
            systemd_pkgs.append(package)
            continue

        apkbuild_path = pmb.helpers.pmaports.find(package)
        apkbuild = pmb.parse._apkbuild.apkbuild(pathlib.Path(apkbuild_path, "APKBUILD"))

        if not pmb.helpers.pmaports.check_arches(apkbuild["arch"], arch):
            print(f"{package}: not enabled for {arch}, skipping")
            packages.remove(package)

    # No packages: skip build
    if len(packages) == 0:
        print(f"no packages changed, which can be built for {arch}")
        sys.exit(0)

    build_strict(packages, arch)

    # Build packages in extra-repos/systemd
    # FIXME: this should probably be more generic, if other repos are added later?
    if systemd_pkgs:
        common.run_pmbootstrap(["config", "systemd", "always"])
        # To fix the ERROR: Chroot 'native' is for the 'edge' channel, but you are on the
        # 'systemd-edge' channel. Run 'pmbootstrap zap' to delete your chroots and try again.
        # To do this automatically, run 'pmbootstrap config auto_zap_misconfigured_chroots yes'.
        common.run_pmbootstrap(["config", "auto_zap_misconfigured_chroots", "yes"])

        # filter out packages that can't be built for arch
        # (Iterate over copy of `systemd_pkgs`, because we modify it in this loop)
        for package in systemd_pkgs.copy():
            apkbuild_path = pmb.helpers.pmaports.find(package, True, True, with_extra_repos="enabled")
            apkbuild = pmb.parse._apkbuild.apkbuild(pathlib.Path(apkbuild_path, "APKBUILD"))
            if not pmb.helpers.pmaports.check_arches(apkbuild["arch"], arch):
                print(f"(extra-repos/systemd) {package}: not enabled for {arch}, skipping")
                systemd_pkgs.remove(package)

        # No packages: skip build
        if len(systemd_pkgs) == 0:
            print(f"no packages changed, which can be built for {arch}")
            sys.exit(0)

        build_strict(systemd_pkgs, arch)
