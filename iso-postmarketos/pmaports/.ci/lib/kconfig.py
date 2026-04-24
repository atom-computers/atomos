#!/usr/bin/env python3
# Copyright 2024 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

import subprocess

# Same dir
import common


def check_kconfig(pkgnames):
    last_failed = None
    for i in range(len(pkgnames)):
        pkgname = pkgnames[i]
        print(f"  ({i+1}/{len(pkgnames)}) {pkgname}")

        p = subprocess.run(["pmbootstrap", "kconfig", "check", "--keep-going", pkgname],
                           check=False)

        if p.returncode:
            last_failed = pkgname

    return last_failed


def check_kconfig_all():
    p = subprocess.run(["pmbootstrap", "kconfig", "check", "--keep-going"], check=False)
    return p.returncode == 0


def show_error(last_failed):
    print("")
    print("---")
    print("")
    print("Please adjust your kernel config. This is required for getting your"
          " patch merged.")
    print("")
    print("Edit your kernel config:")
    print(f"  pmbootstrap kconfig edit {last_failed}")
    print("")
    print("Test this kernel config again:")
    print(f"  pmbootstrap kconfig check {last_failed}")
    print("")
    print("Run this check again (on all kernels you modified):")
    print("  pmbootstrap ci kconfig")
    print("")
    print("---")
    print("")


def show_error_all():
    print("")
    print("---")
    print("")
    print("Please adjust the failed kernel configs. This is required for")
    print("getting your patch merged.")
    print("")
    print("If a kernel in the testing category failed, and fixing is too much")
    print("effort, remove 'pmb:kconfigcheck-community' from the APKBUILD.")
    print("")
    print("Edit a kernel config:")
    print("  pmbootstrap kconfig edit <PACKAGE NAME>")
    print("")
    print("Test a specific kernel config again:")
    print("  pmbootstrap kconfig check <PACKAGE NAME>")
    print("")
    print("Run this check again (on all kernels you modified):")
    print("  pmbootstrap ci kconfig")
    print("")
    print("---")
    print("")


if __name__ == "__main__":
    if "kconfigcheck.toml" in common.get_changed_files():
        print("kconfigcheck.toml changed -> checking all kernels")
        if not check_kconfig_all():
            show_error_all()
            exit(1)
        exit(0)

    pkgnames = common.get_changed_kernels(skip_archived=True)
    print(f"Changed kernels: {pkgnames}")

    if len(pkgnames) == 0:
        print("No kernels changed in this branch")
        exit(0)
    elif common.commit_message_has_string("[ci:skip-kconfigcheck]"):
        print("WARNING: not checking kernel configs ([ci:skip-kconfigcheck])")
        exit(0)

    last_failed = check_kconfig(pkgnames)

    if last_failed:
        show_error(last_failed)
        exit(1)
