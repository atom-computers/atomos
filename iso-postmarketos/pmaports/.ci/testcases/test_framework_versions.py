#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

""" Make sure that components of frameworks (Qt, KDE, ...) have the same
    version in all packages. We scan all packages, categorize them by URL
    and then compare the versions of all packages in each category. """

import logging

import pmb.config
import pmb.parse
from pmb.core.pkgrepo import pkgrepo_iter_package_dirs


def get_categorized_packages():
    """
    Parse all aports and categorize them.

    :returns: {"plasma": {"kwin": "5.13.3", ...},
               "kde": {"kcrash": "5.48.0", ...},
               "qt": {"qt5-qtbase": "5.12.0", ...},
               "other": {"konsole": "1234", ...}}
    """
    ret = {}

    for path in pkgrepo_iter_package_dirs():
        # Parse APKBUILD
        apkbuild = pmb.parse.apkbuild(path)
        url = apkbuild["url"]
        pkgname = apkbuild["pkgname"]
        pkgver = apkbuild["pkgver"]
        if pkgver == "9999":
            pkgver = apkbuild["_pkgver"]

        if "_git" in pkgver:
            continue

        # Categorize by URL
        category = "other"
        if "https://www.kde.org/workspaces/plasmadesktop" in url:
            category = "plasma"
        elif "https://community.kde.org/Frameworks" in url:
            category = "kde"
        elif url in ["http://qt-project.org/",
                     "https://www.qt.io/developers/"]:
            category = "qt"

        # Remove hotfix number (i.e. 5.16.90.1 becomes 5.16.90)
        if category in ["kde", "plasma"]:
            pkgver = ".".join(pkgver.split(".")[0:3])

        # Save result
        if category not in ret:
            ret[category] = {}
        ret[category][pkgname] = pkgver
    return ret


def check_categories(categories):
    """
    Make sure that all packages in one framework (kde, plasma, ...) have the
    same package version (and that there is at least one package in each
    category).

    :param categories: see return of get_categorized_packages()
    :returns: True when the check passed, False otherwise
    """
    ret = True
    for category, packages in categories.items():
        reference = None
        for pkgname, pkgver in packages.items():

            # Use the first package as reference and print a summary
            if not reference:
                logging.info("---")
                logging.info("Package category: " + category)
                logging.info("Packages count: " + str(len(packages)))

                # Category "other": done after printing the basic summary, no
                # need to print each package or compare the package versions
                if category == "other":
                    reference = True
                    break

                # Print all packages
                logging.info("Packages: " + ", ".join(sorted(packages.keys())))

                # Print the reference and skip checking it against itself
                reference = {"pkgname": pkgname, "pkgver": pkgver}
                logging.info("Reference pkgver: " + pkgver + " (from '" +
                             pkgname + "')")
                continue

            # Check version against reference
            if pkgver != reference["pkgver"]:
                logging.info("ERROR: " + pkgname + " has version " + pkgver)
                ret = False

        # Each category must at least have one package
        if not reference:
            logging.info("ERROR: could not find any packages in category: " +
                         category)
            ret = False
    return ret


def test_framework_versions():
    """
    Make sure that packages of the same framework have the same version.
    """
    categories = get_categorized_packages()
    if not check_categories(categories):
        raise RuntimeError("Framework version check failed!")
