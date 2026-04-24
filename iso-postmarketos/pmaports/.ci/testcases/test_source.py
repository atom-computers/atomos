#!/usr/bin/env python3
# Copyright 2023 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
# Various checks on source= in the APKBUILDs

import glob
import logging
import os

import pmb.parse
import pmb.parse._apkbuild
import pmb.parse.apkindex
import pmb.helpers.repo
from pmb.core.pkgrepo import pkgrepo_iter_package_dirs, pkgrepo_relative_path


def parse_source_from_checksums(apkbuild_path):
    """
    Read the APKBUILD file and parse source files from the checksums at the
    bottom. This has always the same format, even if $source is built with hard
    to parse shell code (like in postmarketos-base).

    :param apkbuild_path: full path to the APKBUILD
    :returns: dict of parsed "source" filenames and checksums, e.g.:
              {"first.patch": "b4dc4f3…",
               "second.patch": "b4dc4f3…"}
    """
    start = 'sha512sums="'
    in_block = False
    ret = {}

    with open(apkbuild_path, encoding="utf-8") as handle:
        for line in handle.readlines():
            # Find start
            if not in_block:
                if line.startswith(start):
                    in_block = True
                else:
                    continue

            # sha512sums may have lines without checksums:
            # https://gitlab.alpinelinux.org/alpine/abuild/-/merge_requests/73
            if "  " not in line:
                continue

            try:
                checksum, filename = line.rstrip().split("  ", 2)
            except ValueError:
                raise ValueError("Failed to parse checksums. Try to delete the"
                                 " checksums and generate them again with"
                                 f" 'pmbootstrap checksum': {apkbuild_path}")

            # Cut off 'sha512sums="' if the first checksum is in that line
            if checksum.startswith(start):
                checksum = checksum[len(start):]

            # Find end
            if filename.endswith('"'):
                filename = filename[:-1]

            ret[filename] = checksum
    return ret


def test_aports_unreferenced_files():
    """
    Raise an error if an unreferenced file is found
    """
    for apkbuild_path in pkgrepo_iter_package_dirs():
        # pmbootstrap parser has some issues with complicated APKBUILDs, skip those.
        _, relpath = pkgrepo_relative_path(apkbuild_path)
        if relpath.parts[0] == "cross":
            continue

        apkbuild_path = apkbuild_path / "APKBUILD"

        apkbuild = pmb.parse.apkbuild(apkbuild_path)
        sources_chk = parse_source_from_checksums(apkbuild_path)

        # Collect files from subpackages
        subpackage_installs = []
        subpackage_triggers = []
        if apkbuild["subpackages"]:
            for subpackage in apkbuild["subpackages"].values():
                if not subpackage:
                    continue
                subpackage_installs += subpackage.get("install", [])
                subpackage_triggers += subpackage.get("triggers", [])

        # Collect trigger files
        trigger_sources = []
        for trigger in apkbuild["triggers"] + subpackage_triggers:
            trigger_sources.append(trigger.split("=")[0])

        dirname = os.path.dirname(apkbuild_path)
        for file in glob.iglob(dirname + "/**", recursive=True):
            rel_file_path = os.path.relpath(file, dirname)
            # Skip APKBUILDs and directories
            if rel_file_path in ["APKBUILD", "gitlab-ci.yml.j2"] or os.path.isdir(file):
                continue
            # Skip kernel fragments in linux-* packages
            if os.path.basename(rel_file_path).endswith(".config") and apkbuild["pkgname"].startswith("linux-"):
                continue

            if os.path.basename(rel_file_path) not in sources_chk \
                    and rel_file_path not in apkbuild["install"] \
                    and rel_file_path not in subpackage_installs \
                    and rel_file_path not in trigger_sources \
                    and not rel_file_path.startswith("tests/"):
                raise RuntimeError(f"{apkbuild_path}: found unreferenced file: {rel_file_path}")


def test_distfiles_conflict():
    """
    Make sure that each filename mentioned in any source= of any APKBUILD
    always has the same checksum. This is important because apk caches
    downloaded source files in a flat distfiles directory. So if two APKBUILDs
    both download a file with the same filename but different checksum, and the
    user builds both after each other, abuild will fail on the second build
    with a checksum error.
    """
    source_all = {}
    for apkbuild_path in pkgrepo_iter_package_dirs():
        apkbuild_path = apkbuild_path / "APKBUILD"
        source = parse_source_from_checksums(apkbuild_path)
        dir_path = os.path.dirname(apkbuild_path)
        _, apkbuild_rel = pkgrepo_relative_path(apkbuild_path)
        for filename, checksum in source.items():
            # Files bundled with the APKBUILD don't get copied to the distfiles
            # cache, so not relevant for this check. Use glob.glob here and not
            # iglob, because we don't want an iterator.
            if glob.glob(f"{dir_path}/**/{filename}", recursive=True):
                continue

            # First time seeing this file
            if filename not in source_all:
                source_all[filename] = {"checksum": checksum,
                                        "apkbuild_rel": apkbuild_rel}
                continue

            # Saw this file already with same checksum
            if checksum == source_all[filename]["checksum"]:
                continue

            # Saw this file already with different checksum
            logging.error("")
            logging.error(f"ERROR: the source file '{filename}' has different"
                          " checksums in the following files:")
            logging.error(f"- {source_all[filename]['apkbuild_rel']}:")
            logging.error(f"  {source_all[filename]['checksum']}")
            logging.error(f"- {apkbuild_rel}:")
            logging.error(f"  {checksum}")
            logging.error("")
            logging.error("Fix this by setting a different target filename in"
                          " the package you modified:")
            logging.error("https://wiki.alpinelinux.org/wiki/APKBUILD_Reference#source")
            logging.error("")
            raise RuntimeError(f"Conflict with source file '{filename}'")
