# Kernel Versions

Generally speaking, maintainers have the freedom to package any kernel version
they desire for their devices. However, the choice affects the categories that
the device may be eligible for and we strongly recommend following some
additional guidelines for which kernel version to package for a device.

## Categorization

Devices with a close-to-mainline kernel usually reside in `testing` and can be
moved to `community` or `main` later if they meet the necessary
[requirements](./device-categorization.md). Devices using a downstream (i.e.
vendor-provided) kernel are packaged in the `downstream` or `archived`
categories.

## What To Package

We strongly advise **against** using any
[linux-next](https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git)
version as the kernel packaged for devices. linux-next is used for integration
testing and as a base for patch submission, but is by no means stable and
therefore we discourage packaging it. One exception to this is the
`device-postmarketos-trailblazer` device package - it is intended to be a
bleeding edge target reflecting the very latest state of upstream.

Further, we do not recommend packaging the first release candidate (-rc1)
tagged after the merge window is closed. The first release candidate introduces
a lot of new changes, after which only fixes are admitted into the kernel tree.
Therefore, subsequent release candidates tend to be more stable than the first.
We recommend waiting until at least -rc2 before packaging a new major kernel
release.
