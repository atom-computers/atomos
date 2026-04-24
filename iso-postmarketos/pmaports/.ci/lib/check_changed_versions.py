#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

import glob
import pathlib
import tempfile
import sys
import subprocess

# Same dir
import common

# pmbootstrap
import pmb.parse
import pmb.parse.version
import pmb.helpers.logging
from pmb.core.context import get_context

def get_package_contents(package, revision, check=True):
    # Redirect stderr to /dev/null, so git doesn't complain about files not
    # existing in upstream branch for new packages
    stderr = None
    if not check:
        stderr = subprocess.DEVNULL

    # Run something like "git show upstream/main:main/hello-world/APKBUILD"
    pmaports_dir = common.get_pmaports_dir()
    pattern = pmaports_dir + "/**/" + package + "/APKBUILD"
    path = glob.glob(pattern, recursive=True)[0][len(pmaports_dir + "/"):]
    apkbuild_content = common.run_git(["show", revision + ":" + path], check,
                                      stderr)
    if not apkbuild_content:
        return None

    # Save APKBUILD to a temporary path and parse it from there. (Not the best
    # way to do things, but good enough for this CI script.)
    with tempfile.TemporaryDirectory() as tempdir:
        with open(tempdir + "/APKBUILD", "w", encoding="utf-8") as handle:
            handle.write(apkbuild_content)
        parsed = pmb.parse.apkbuild(pathlib.Path(tempdir, "APKBUILD"),
                                    False, False)

    return parsed


def get_package_version(package, revision, check=True):
    """ returns version in the format "{pkgver}-r{pkgrel}", or None if no
        matching package is found """
    parsed = get_package_contents(package, revision, check)
    if parsed is None:
        return None
    return parsed["pkgver"] + "-r" + parsed["pkgrel"]


def version_compare_operator(result):
    """ :param result: return value from pmb.parse.version.compare() """
    if result == -1:
        return "<"
    elif result == 0:
        return "=="
    elif result == 1:
        return ">"

    raise RuntimeError("Unexpected version_compare_operator input: " + result)


def exit_with_error_message():
    branch = common.get_upstream_branch()
    print()
    print("ERROR: Modified package(s) don't have an increased version or a")
    print("new package has a nonzero pkgrel!")
    print()
    print("This can happen if you added a new package with a nonzero")
    print("pkgrel, or if you did not change the pkgver/pkgrel")
    print("variables in the APKBUILDs. Or you did change them, but the")
    print(f"packages have been updated in the official '{branch}' branch, and")
    print("now your versions are not higher anymore.")
    print()
    print("Your options:")
    print("a) If you made changes to the packages, and did not increase the")
    print("   pkgrel/pkgver: increase them now, and force push your branch.")
    print("   => https://postmarketos.org/howto-bump-pkgrel-pkgver")
    print("b) If you had already increased the package versions, rebase on")
    print(f"   '{branch}', increase the versions again and then force push:")
    print("   => https://postmarketos.org/rebase")
    print("c) If you made a change, that does not require rebuilding the")
    print("   packages, such as only changing the arch=... line: you can")
    print("   disable this check by adding '[ci:skip-vercheck]' to the")
    print("   latest commit message, then force push.")
    print()
    print("Thank you and sorry for the inconvenience.")
    exit(1)


def check_versions(packages):
    error = False

    # Get relevant commits: compare HEAD against upstream branch or HEAD~1
    # (the latter if this CI check is running on upstream branch). Note that
    # for the common.get_changed_files() code, we don't check against
    # upstream branch HEAD, but against the latest common ancestor. This is not
    # desired here, since we already know what packages changed, and really
    # want to check if the version was increased towards *current* upstream
    # branch HEAD.
    common.run_git(["remote", "add", "upstream",
             "https://gitlab.postmarketos.org/postmarketOS/pmaports.git"], False)
    common.run_git(["fetch", "-q", "upstream"])
    commit = f"upstream/{common.get_upstream_branch()}"
    if common.run_git(["rev-parse", "HEAD"]) == common.run_git(["rev-parse",
                                                                commit]):
        print(f"NOTE: {commit} is on same commit as HEAD, comparing"
              " HEAD against HEAD~1.")
        commit = "HEAD~1"

    # Exclude linux-next from pkgrel checks, as it is updated automatically.
    #
    # Without this, .ci/commits.sh complains about the following:
    # ERROR: Modified package(s) don't have an increased version or a new
    #        package has a nonzero pkgrel!
    if "linux-next" in packages:
        packages.remove("linux-next")

    for package in packages:
        # Get versions, skip new packages
        head = get_package_version(package, "HEAD")
        upstream = get_package_version(package, commit, False)
        if not upstream:
            if head.rpartition('r')[2] != "0":
                print(f"- {package}: {head} (HEAD) (new package) [ERROR]")
                error = True
            else:
                print(f"- {package}: {head} (HEAD) (new package)")
            continue

        # Check pkgver follows expected format for device packages
        pkgver = head.rpartition('-r')[0]
        if package.startswith('device-') and not pkgver.isdigit():
            print(f" - {package}: invalid pkgver \"{pkgver}\""
                  "See: https://docs.postmarketos.org/pmaports/main/packaging-guidelines.html#package-versioning-pkgver-pkgrel")
            error = True

        # Additional checks for device packages
        if package.startswith('device-'):
            head_parsed = get_package_contents(package, "HEAD", False)
            upstream_parsed = get_package_contents(package, commit, False)

            # Check that pkgrel was reset to 0 when pkgver was changed
            if head_parsed["pkgver"] != upstream_parsed["pkgver"] and head_parsed["pkgrel"] != "0":
                print(f" - {package}: pkgrel should be 0 when pkgver changes."
                      "See: https://docs.postmarketos.org/pmaports/main/packaging-guidelines.html#package-versioning-pkgver-pkgrel")
                error = True

        # Compare head and upstream versions
        result = pmb.parse.version.compare(head, upstream)
        if result != 1:
            error = True

        # Print result line ("- hello-world: 1-r2 (HEAD) > 1-r1 (HEAD~1)")
        formatstr = "- {}: {} (HEAD) {} {} ({})"
        if result != 1:
            formatstr += " [ERROR]"
        operator = version_compare_operator(result)
        print(formatstr.format(package, head, operator, upstream, commit))

    if error:
        exit_with_error_message()


if __name__ == "__main__":
    # Get and print modified packages
    packages = common.get_changed_packages()
    if len(packages) == 0:
        print("no aports changed in this branch")
        exit(0)

    print(f"Changed packages: {packages}")

    # Potentially skip this check
    if common.commit_message_has_string("[ci:skip-vercheck]"):
        print("WARNING: not checking for changed package versions"
              " ([ci:skip-vercheck])!")
        exit(0)

    # Initialize args (so we can use pmbootstrap's APKBUILD parsing)
    sys.argv = ["pmbootstrap.py", "chroot"]
    args = pmb.parse.arguments()
    context = get_context()

    # pmb.helpers.logging.init(args)
    pmb.helpers.logging.init(context.log, args.verbose, context.details_to_stdout)


    # Verify package versions
    print("checking changed package versions...")
    check_versions(packages)
