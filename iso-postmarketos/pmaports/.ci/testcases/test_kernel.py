#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

import os
import re

import pmb.parse
from pmb.core.pkgrepo import pkgrepo_iglob, pkgrepo_relative_path


def test_aports_kernel():
    """
    Various tests performed on the /**/linux-* aports.
    """

    for path in pkgrepo_iglob("**/linux-*/APKBUILD", recursive=True):
        apkbuild = pmb.parse.apkbuild(path)
        aport_name = os.path.basename(os.path.dirname(path))

        if aport_name == "linux-pam-pmos":
            continue  # This package isn't a linux kernel!

        if aport_name == "linux-postmarketos-allwinner":
            continue  # Hack to work around issue (see git blame)

        if "pmb:cross-native" not in apkbuild["options"]:
            raise RuntimeError(f"{aport_name}: \"pmb:cross-native\" missing in"
                               " options= line")

        # cross-compilers should not be in makedepends
        for ccc in ["gcc-armv7", "gcc-armhf", "gcc-aarch64",
                    "gcc4-armv7", "gcc4-armhf", "gcc4-aarch64",
                    "gcc6-armv7", "gcc6-armhf", "gcc6-aarch64"]:
            if ccc in apkbuild["makedepends"]:
                raise RuntimeError(f"{aport_name}: Cross-compiler ({ccc}) should"
                                   " not be explicitly specified in makedepends!"
                                   " pmbootstrap installs cross-compiler"
                                   " automatically.")

        # check some options only for main and community devices
        _, relpath = pkgrepo_relative_path(path)
        for part in ["main", "community"]:
            if part in relpath.parts:
                if "pmb:kconfigcheck-community" not in apkbuild["options"]:
                    raise RuntimeError(f"{aport_name}: \"pmb:kconfigcheck-community\" missing in"
                                       " options= line, required for all community/main devices.")

        # check for postmarketos-installkernel in makedepends when installing kernel with make
        if bool(re.search("make z?install", path.read_text(encoding="utf-8"))):
            if "postmarketos-installkernel" not in apkbuild["makedepends"]:
                raise RuntimeError(f"{aport_name}: \"postmarketos-installkernel\" missing in"
                                   " makedepends, required when using make install/zinstall.")
