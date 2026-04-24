#!/usr/bin/env python3
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

# Various functions used in CI scripts

import configparser
import os
import subprocess
from functools import cache


@cache
def get_pmaports_dir():
    return os.path.realpath(os.path.join(os.path.dirname(__file__) + "/../.."))


def run_git(parameters, check=True, stderr=None):
    """ Run git in the pmaports dir and return the output """
    cmd = ["git", "-C", get_pmaports_dir()] + parameters
    try:
        return subprocess.check_output(cmd, stderr=stderr).decode()
    except subprocess.CalledProcessError:
        if check:
            raise
        return None


def commit_message_has_string(needle):
    base_commit = get_base_commit()

    return needle in run_git(["log", "--pretty=format:%B", f"{base_commit}..HEAD"])


def all_committed_by_merge_bot():
    base_commit = get_base_commit()
    commit_emails = run_git(["log", "--pretty=format:%ce", f"{base_commit}..HEAD"]).splitlines()
    bot_email = os.getenv("PMOS_MERGE_BOT_EMAIL", "merge-bot@postmarketos.org")
    return all(bot_email == ce for ce in commit_emails)


def run_pmbootstrap(parameters):
    """ Run pmbootstrap with the pmaports dir as --aports """
    cmd = ["pmbootstrap", "--aports", get_pmaports_dir()] + parameters
    subprocess.run(cmd, universal_newlines=True, check=True)


@cache
def get_upstream_branch():
    """ Use pmaports.cfg from current branch (e.g. "v20.05_fix-ci") and
        channels.cfg from main to retrieve the upstream branch.

        :returns: branch name, e.g. "v20.05" """

    # Prefer gitlab CI target branch name if it's set (i.e. running in gitlab CI)
    if target_branch := os.environ.get("CI_MERGE_REQUEST_TARGET_BRANCH_NAME"):
        return target_branch

    # Get channel (e.g. "stable") from pmaports.cfg
    # https://postmarketos.org/pmaports.cfg
    pmaports_dir = get_pmaports_dir()
    pmaports_cfg = configparser.ConfigParser()
    pmaports_cfg.read(f"{pmaports_dir}/pmaports.cfg")
    channel = pmaports_cfg["pmaports"]["channel"]

    # Get branch_pmaports (e.g. "v20.05") from channels.cfg
    # https://postmarketos.org/channels.cfg
    channels_cfg_str = run_git(["show", "upstream/main:channels.cfg"])
    channels_cfg = configparser.ConfigParser()
    channels_cfg.read_string(channels_cfg_str)
    assert channel in channels_cfg, \
        f"Channel '{channel}' from pmaports.cfg in your branch is unknown." \
        " This appears to be an old branch, consider recreating your change" \
        " on top of master."

    return channels_cfg[channel]["branch_pmaports"]


@cache
def get_base_commit() -> str:
    """Get the base commit that can be compared with HEAD to get all commits in the
    given branch/merge request."""

    commit = os.getenv("CI_MERGE_REQUEST_DIFF_BASE_SHA")
    if commit is not None:
        return commit

    # Add a remote pointing to postmarketOS/pmaports
    run_git(["remote", "add", "upstream",
             "https://gitlab.postmarketos.org/postmarketOS/pmaports.git"], False)
    run_git(["fetch", "-q", "upstream"])

    branch_upstream = f"upstream/{get_upstream_branch()}"
    commit_head = run_git(["rev-parse", "HEAD"])[:-1]
    commit_upstream = run_git(["rev-parse", branch_upstream])[:-1]
    print("commit HEAD: " + commit_head)
    print(f"commit {branch_upstream}: {commit_upstream}")

    # Check if we are HEAD on the upstream branch
    if commit_head == commit_upstream:
        # then compare with previous commit
        commit = "HEAD~1"
    else:
        # otherwise compare with latest common ancestor
        commit = run_git(["merge-base", branch_upstream, "HEAD"])[:-1]
    print("comparing HEAD with: " + commit)

    return commit


def get_changed_files(removed=False):
    """ Get all changed files and print them, as well as the branch and the
        commit that was used for the diff.
        :param removed: also return removed files (default: True)
        :returns: set of changed files
    """
    commit = get_base_commit()

    # Changed files
    ret = set()
    print("changed file(s):")
    for file in run_git(["diff", "--name-only", commit, "HEAD"]).splitlines():
        message = "  " + file
        if not os.path.exists(file):
            message += " (deleted)"
            if removed:
                ret.add(file)
        else:
            ret.add(file)
        print(message)
    return ret


def get_changed_packages(skip_archived: bool = False):
    ret = set()
    for file in get_changed_files(removed=True):
        dirname, filename = os.path.split(file)

        # Skip files:
        # * in the root dir of pmaports (e.g. README.md)
        # * path with a dot (e.g. .ci/, device/.shared-patches/)
        # * documentation
        if (
                not dirname
                or file.startswith(".")
                or "/." in file
                or skip_archived and dirname.startswith("device/archived")
                or dirname == "docs"
        ):
            continue

        if filename != "APKBUILD":
            # Walk up directories until we (eventually) find the package
            # the file belongs to (could be in a subdirectory of a package)
            while dirname and not os.path.exists(os.path.join(dirname, "APKBUILD")):
                dirname = os.path.dirname(dirname)

            # Unable to find APKBUILD the file belong to
            if not dirname:
                # ... maybe the package was deleted entirely?
                if not os.path.exists(file):
                    continue

                # Weird, file does not belong to any package?
                # Here we just warn, there is an extra check
                # to make sure that files are organized properly.
                print(f"WARNING: Changed file {file} does not belong to any package")
                continue

        elif not os.path.exists(file):
            continue  # APKBUILD was deleted

        ret.add(os.path.basename(dirname))

    return ret


def get_changed_kernels(skip_archived: bool = False):
    ret = []
    for pkgname in get_changed_packages(skip_archived):
        if pkgname.startswith("linux-"):
            ret += [pkgname]
    return ret

def get_changed_devices(skip_archived: bool = False):
    ret = []
    for pkgname in get_changed_packages(skip_archived):
        if pkgname.startswith("device-"):
            ret += [pkgname]
    return ret
