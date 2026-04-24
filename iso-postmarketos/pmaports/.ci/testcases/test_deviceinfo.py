#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

import re

import pmb.parse
from pmb.core.pkgrepo import pkgrepo_iglob


def test_deviceinfo():
    """
    Parse all deviceinfo files successfully and run checks on the parsed data.
    """
    # Iterate over all devices
    last_exception = None
    count = 0
    pattern = re.compile("^deviceinfo_[a-zA-Z0-9_]*=\".*\"(\\s*# .*)?$")

    for folder in pkgrepo_iglob("device/*/device-*"):
        device = folder.name.split("-", 1)[1]

        f = open(folder / "deviceinfo")
        lines = f.read().split("\n")
        f.close()

        try:
            for line in lines:
                # Skip empty lines and comments
                if not line or line.startswith("# "):
                    continue

                # Check line against regex (can't use multiple lines etc.)
                if not pattern.match(line) or line.endswith("\\\""):
                    raise RuntimeError("Line looks invalid, maybe missing"
                                       " quotes/multi-line string/malformed"
                                       f" inline comment? {line}")

            # Successful deviceinfo parsing / obsolete options
            info = pmb.parse.deviceinfo(device)

            # deviceinfo_name must start with manufacturer
            name = info.name
            manufacturer = info.manufacturer
            if not name.startswith(manufacturer) and \
                    not name.startswith("Google") and \
                    not name.startswith("Jolla"):
                raise RuntimeError("Please add the manufacturer in front of"
                                   " the deviceinfo_name, e.g.: '" +
                                   manufacturer + " " + name + "'")

        # Don't abort on first error
        except Exception as e:
            last_exception = e
            count += 1
            print(device + ": " + str(e))

    # Raise the last exception
    if last_exception:
        print("deviceinfo error count: " + str(count))
        raise last_exception
