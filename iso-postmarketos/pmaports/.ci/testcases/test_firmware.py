#!/usr/bin/env python3
# Copyright 2021 Johannes Marbach
# SPDX-License-Identifier: GPL-3.0-or-later

import os

import pmb.parse
from pmb.core.pkgrepo import pkgrepo_iglob


def test_aports_firmware():
    """
    Various tests performed on the /**/firmware-* aports.
    """

    excluded = [
        "firmware-motorola-ali",  # Depends on firmware-qcom-adreno-a530
        "firmware-motorola-potter",  # Depends on soc-qcom-msm8916-ucm
        "firmware-oneplus-msm8998",  # Depends on soc-qcom-sdm845-nonfree-firmware
        "firmware-xiaomi-sagit",  # Depends on soc-qcom-sdm845-nonfree-firmware
        "firmware-samsung-baffinlite",  # Depends on firmware-aosp-broadcom-wlan
        "firmware-samsung-crespo",  # Depends on firmware-aosp-broadcom-wlan
        "firmware-samsung-maguro",  # Depends on firmware-aosp-broadcom-wlan
        "firmware-xiaomi-ferrari",  # Depends on soc-qcom-msm8916
        "firmware-xiaomi-willow",  # Doesn't build, source link is dead (pma#1212)
        "firmware-samsung-i9105p", # Depends on firmware-aosp-broadcom-wlan
    ]

    for path in pkgrepo_iglob("**/firmware-*/APKBUILD", recursive=True):
        apkbuild = pmb.parse.apkbuild(path)
        aport_name = os.path.basename(path.parent)

        if aport_name not in excluded:
            if "pmb:cross-native" not in apkbuild["options"]:
                raise RuntimeError(f"{aport_name}: \"pmb:cross-native\" missing in"
                                   " options= line. The pmb:cross-native option is"
                                   " preferred because it results in significantly"
                                   " lower build times. If the package doesn't build"
                                   " with the option, you can add an exemption in"
                                   " .gitlab-ci/testcases/test_firmware.py.")

        if "!tracedeps" not in apkbuild["options"]:
            raise RuntimeError(f"{aport_name}: \"!tracedeps\" missing in"
                               " options= line. The tracedeps option is superfluous"
                               " for firmware packages.")

        if "noarch" in apkbuild["arch"]:
            raise RuntimeError(f"{aport_name}: \"arch\" must not be \"noarch\"!"
                               " Please limit this firmware package to the"
                               " required architectures only!")
