#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

from pathlib import Path

import common
import pmb.parse


def test_aports_ui():
    """
    Raise an error if package in _pmb_recommends is not found
    """
    pmaports_cfg = pmb.config.pmaports.read_config()
    for arch in pmaports_cfg["supported_arches"].split(","):
        for path in common.get_changed_files():
            path = Path(path)

            if path.name != "APKBUILD":
                continue
            if not path.parent.name.startswith("postmarketos-ui"):
                continue

            apkbuild = pmb.parse.apkbuild(path)
            # Skip if arch isn't enabled
            if not pmb.helpers.package.check_arch(apkbuild["pkgname"], arch, False):
                continue

            for package in apkbuild["_pmb_recommends"]:
                depend = pmb.helpers.package.get(
                    package, arch, must_exist=False, try_other_arches=False
                )
                if depend is None:
                    raise RuntimeError(f"{path}: package '{package}' from"
                                       f" _pmb_recommends not found for arch '{arch}'")

            # Check packages from "_pmb_recommends" of -extras subpackage if one exists
            if f"{apkbuild['pkgname']}-extras" in apkbuild["subpackages"]:
                apkbuild = apkbuild["subpackages"][f"{apkbuild['pkgname']}-extras"]
                for package in apkbuild["_pmb_recommends"]:
                    depend = pmb.helpers.package.get(
                        package, arch, must_exist=False, try_other_arches=False
                    )
                    if depend is None:
                        raise RuntimeError(f"{path}: package '{package}' from _pmb_recommends "
                                           f"of -extras subpackage is not found for arch '{arch}'")
