# Generic Device Packages

This article is about device packages starting with `device-generic-`. These
can boot on multiple devices of that architecture. `device-generic-x86_64`
could for example be booted on most PCs and laptops with that architecture.

## Device-specific services

Pre-installing device specific software is allowed if it is needed to enable
device functionality, but it must only start on relevant devices and not
break other devices.

One example is the
[hexagonrpcd](https://github.com/linux-msm/hexagonrpc) daemon for serving
HexagonFS files to the DSPs on Qualcomm devices, which we only run if e.g.
`/dev/fastrpc-adsp` is available.
