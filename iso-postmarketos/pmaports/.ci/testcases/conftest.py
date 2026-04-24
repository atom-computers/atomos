#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

from pathlib import Path
import pmb.parse
from pmb.helpers.args import init as init_args
from pmb.types import PmbArgs
import pmb.config
import pytest
import os

@pytest.fixture(scope="session", autouse=True)
def args(request):
    # Initialize args
    pmaports = Path(os.path.realpath(f"{os.path.dirname(__file__)}/../.."))
    args = PmbArgs()
    args.aports = [pmaports]
    args.config = pmb.config.defaults["config"]
    args.timeout = 900
    args.details_to_stdout = False
    args.quiet = False
    args.verbose = True
    args.offline = False
    args.action = "init"
    args.cross = False
    args.ccache = False
    args.log = None

    init_args(args)
    request.addfinalizer(pmb.helpers.logging.logfd.close)
    return args
