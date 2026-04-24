#!/usr/bin/env python3
# Copyright 2025 Stefan Hansson
# SPDX-License-Identifier: GPL-3.0-or-later

import common
import glob
import os.path
import subprocess
import sys

if __name__ == "__main__":
    if common.commit_message_has_string("[ci:skip-dint]"):
        print("WARNING: not linting deviceinfo files ([ci:skip-dint])")
        exit(0)

    if "deviceinfo_schema.toml" in common.get_changed_files():
        print("deviceinfo_schema.toml changed -> checking all deviceinfo files")
        pmaports_dir = common.get_pmaports_dir()
        deviceinfo_files = set(glob.glob(pmaports_dir + "/device/*/*/deviceinfo"))
    else:
        # only lint deviceinfo files in the devices repo
        deviceinfo_files = {file for file in common.get_changed_files()
                            if os.path.basename(file) == "deviceinfo" and file.startswith("device/")}

    try:
        subprocess.run(["dint", "check", *deviceinfo_files], text=True, check=True)
    except subprocess.CalledProcessError as exception:
        sys.exit(exception.returncode)
