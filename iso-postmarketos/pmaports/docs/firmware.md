# Firmware

Firmware (non-free binary blobs, often cryptographically signed by the OEM)
is nowadays unfortunately required for a lot of essential functionality,
especially on mobile devices with wireless connectivity or graphics processors.

## User choice

While for the longest time, pmbootstrap used to prompt the user whether they
wanted to install firmware or not, it was decided in early 2024 that nonfree
firmware would be [installed by
default](https://postmarketos.org/edge/2024/02/15/default-nonfree-fw/).

Nonfree firmware dependencies should therefore now be in the `depends` of the
device package and also not in a separate subpackage. It would technically be
possible to put it in `_pmb_recommends` as well to allow users to uninstall it
later, but that is not recommended for the reasons discussed in the blog post.
Maintainers will have an easier time troubleshooting bug reports if they do not
need to account for the possibility that the user may have uninstalled required
firmware dependencies. Any such setup should therefore be considered custom,
and not something maintainers will generally be able to help with.

## Packaging

There are three endorsed methods for providing the nonfree firmware to the
kernel, in order of preference:

1. Using firmware files already in `linux-firmware` upstream
2. Packaging them in pmaports, e.g. a `firmware-vendor-device` package
3. Reusing the firmware present on a partition on the device

Firmware files in `linux-firmware` should be preferred if possible and not
repackaged in pmaports, with exceptions possible to make the installed firmware
more granular. This is for example done for the Qualcomm Adreno GPU firmware in
pmaports, which is packaged as `firmware-qcom-adreno-*` and allows device
packages to depend on their GPU firmware without pulling in the entirety of
`linux-firmware-qcom`. Similar such packages may be added in the future and
should be preferred over the larger packages where possible.

When that is not possible, for example because the vendors did not send the
firmware upstream, it is recommended to package the firmware files directly in
pmaports. It prevents potential race conditions between services and greatly
simplifies the setup, making it easier to reason about what is going on in the
system. It is also generally considered the most secure alternative. CVEs in
non-free firmware for things like the modem have existed. Packaging firmware and
keeping it up-to-date ensures that all users get the newest security patches,
and do not depend on the Android version they had before installing
postmarketOS.

Unfortunately, there are cases where none of the other options are possible, for
example, when firmware files are specific to the device: unit-specific
calibration data, region-specific WiFi or modem firmware files, etc. In those
cases it is reasonable to load the firmware from e.g. the Android partition
with those files. This can be done using
[msm-firmware-loader](https://gitlab.postmarketos.org/postmarketOS/msm-firmware-loader),
which, despite the name, can be modified to suit other devices than just
Qualcomm-based ones. Extremely space-constrained devices may also use this
approach if required.
