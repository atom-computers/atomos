#!/usr/bin/env python3
# Copyright 2025 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
import logging
import os

import pmb.parse
from pmb.core.context import get_context
from pathlib import Path


def test_systemd_stage0_version():
    """Ensure systemd-stage0 and systemd have the same pkgver."""
    # Don't clutter output with verbose APKBUILD parsing messages
    logging.getLogger().setLevel(logging.DEBUG)

    config = get_context().config
    pma_systemd = os.path.join(config.aports[0], "extra-repos/systemd")

    sd0 = pmb.parse.apkbuild(Path(os.path.join(pma_systemd, "systemd-stage0/APKBUILD")))
    sd1 = pmb.parse.apkbuild(Path(os.path.join(pma_systemd, "systemd/APKBUILD")))

    assert sd0["pkgver"] == sd1["pkgver"], (
        f"systemd-stage0 pkgver ({sd0['pkgver']}) doesn't match systemd pkgver ({sd1['pkgver']})!"
    )
