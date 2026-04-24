#!/usr/bin/env python3
# Copyright 2025 Pablo Correa Gomez
# SPDX-License-Identifier: GPL-3.0-or-later
import os
import sys

# Same dir
import common

# pmbootstrap
import pmb.core
from pmb.core.context import get_context


def verify_checksums(packages):
    if len(packages) == 0:
        print("no packages changed, not doing any checksums verification")
        return

    print("verifying checksums: " + ", ".join(packages))
    common.run_pmbootstrap(["build_init"])
    common.run_pmbootstrap(["--details-to-stdout", "checksum", "--verify"] +
                           list(packages))


if __name__ == "__main__":
    # Get and print modified packages
    packages = common.get_changed_packages()

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

    # To store a list of packages from extra-repos/systemd for special handling
    #  later:
    systemd_pkgs = list()

    # Filter out packages are not found in enabled repos
    # (Iterate over copy of packages, because we modify it in this loop)
    for package in packages.copy():
        if package not in buildable_pkgs:
            print(f"{package}: not in current repo, skipping")
            packages.remove(package)
            # FIXME: this should probably be more generic, if other repos are added
            #  later?
            # This just tosses the package into the list of packages to try
            # building later w/ systemd enabled, and assumes it'll be found
            # there.
            print(f"{package}: adding to list of packages to check in systemd repo")
            systemd_pkgs.append(package)
            continue

    # No packages: skip build
    if len(packages) == 0:
        print("no packages to check for the current repo")
    else:
       verify_checksums(packages)

    # FIXME: this should probably be more generic, if other repos are added later?
    if systemd_pkgs:
        common.run_pmbootstrap(["config", "systemd", "always"])
        # To fix the ERROR: Chroot 'native' is for the 'edge' channel, but you are on the
        # 'systemd-edge' channel. Run 'pmbootstrap zap' to delete your chroots and try again.
        # To do this automatically, run 'pmbootstrap config auto_zap_misconfigured_chroots yes'.
        common.run_pmbootstrap(["config", "auto_zap_misconfigured_chroots", "yes"])

        # No packages: skip build
        if len(systemd_pkgs) == 0:
            print("no packages to check for the systemd repo")

        else:
            verify_checksums(systemd_pkgs)
