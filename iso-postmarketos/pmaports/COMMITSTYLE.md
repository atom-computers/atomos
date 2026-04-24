# Policy for commits in pmaports

This document defines policy for organising and titling commits for
inclusion in pmaports.

## Definitions

### Device-specific package

A device-specific package is used to apply configuration and
functionality specifically for device support in postmarketOS.
This is in contrast to other packages
(e.g. main/postmarketos-ui-phosh) in postmarketOS that are used
for configuring the distribution without consideration of the
target device.

## General policy

We follow Alpine's aports commit style with some minor exceptions
and additions. Alpine's commit style can be found here:
https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/COMMITSTYLE.md

## Exceptions

### Changes to packages inside of the device directory

While Alpine has the policy of always prefixing package names with
the name of the repository they are in, in the case of pmaports
this can lead to excessively long commit titles due to the nested
subfolders of the device directory. As such, commits changing
packages inside of the device directory should omit the directory
prefix, for example:

    device-pine64-pinephone: description of change

Or:

    soc-qcom-msm8996: description of change

If the commit only makes device-specific changes, the
commit title can opt to use the following format:

    manufacturer-codename: description of change

### Changes to packages inside of the systemd directory

We also shorten the prefixes for packages in `extra-repos/systemd`.
When the `systemd` package itself gets changed, use `systemd: ` as
prefix. For example:

    systemd: add triggers for reloading/restarting services

When another package inside the systemd directory gets changed, use
`systemd/$pkgname: ` as prefix. For example:

    systemd/cups: restart on upgrade

### Moving devices between categories

As we do not include directory prefixes in device-related commits,
Alpine's commit style for moving packages does not apply. Instead,
we do the following:

    manufacturer-codename: move from category to category

For example:

    samsung-m0: move from testing to community

## Additions

### Forking packages from Alpine

Run `pmbootstrap aportgen --fork-alpine package` and modify it.

#### Template

 - temp/package-name: fork from Alpine

Example: temp/pulseaudio: fork from Alpine

#### Rules

One commit per forked package.

### Adding new devices

Adding a new device package and optionally also a device-specific
Linux and firmware package.

#### Template

 - manufacturer-codename: new device

Example: htc-m8qlul: new device

#### Rules

If the device has the option of making use of a device-specific
kernel and/or firmware package, those packages should be included
in the same commit that adds the device package. One device per
commit.
