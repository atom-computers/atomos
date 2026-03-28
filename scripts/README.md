# Bluetooth Tool Commands (Image Install Map)

This file documents the Bluetooth-related tools that are installed into the image by:

- `iso-postmarketos/scripts/rootfs/install-btlescan.sh`
- `iso-postmarketos/scripts/rootfs/install-bt-tools.sh`

For each tool, it shows:

- the command available in `PATH`
- the installed executable path
- the installed source location on-device
- a short description

## Commands Available In PATH

| Tool | PATH Command | Executable Path(s) | Installed Source Path | Description |
|---|---|---|---|---|
| btlescan | `btlescan` | `/usr/local/bin/btlescan` (symlink: `/usr/bin/btlescan`) | n/a (installed binary) | Rust BLE scanner utility. |
| badblue | `badblue` | `/usr/local/bin/badblue` (symlink: `/usr/bin/badblue`) | `/usr/local/share/atomos/badblue.py` | Bluetooth scanner / flood helper script wrapper. |
| Cerberus Blue | `cerberusblue` | `/usr/local/bin/cerberusblue` (symlink: `/usr/bin/cerberusblue`) | `/usr/local/share/atomos/cerberusblue/` | Advanced Bluetooth pentest CLI (`cerberusblue.py`). |
| blue-deauth | `blue-deauth` | `/usr/local/bin/blue-deauth` (symlink: `/usr/bin/blue-deauth`) | `/usr/local/share/atomos/blue-deauth/` | Simple BLE/BR deauth flood script wrapper. |
| BlueToolkit | `bluekit` | `/usr/local/bin/bluekit` (symlink: `/usr/bin/bluekit`) | `/usr/share/BlueToolkit/` | BlueToolkit engine CLI (recon/exploit/report framework). |
| bluing | `bluing` | `/usr/local/bin/bluing` (symlink: `/usr/bin/bluing`) | `/usr/local/share/atomos/bluing/` | Bluetooth intelligence gathering CLI. |
| WhisperPair (CVE-2025-36911) | `whisperpair` | `/usr/local/bin/whisperpair` (symlink: `/usr/bin/whisperpair`) | `/usr/local/share/atomos/whisperpair/` | Fast Pair CVE test/exploit CLI. |
| BTLE Python scripts | `btle-python` | `/usr/local/bin/btle-python` (symlink: `/usr/bin/btle-python`) | `/usr/local/share/atomos/btle/` | Runner for BTLE repo Python scripts. |
| BleedingTooth exploit | `bleedingtooth-exploit` | `/usr/local/bin/bleedingtooth-exploit` (symlink: `/usr/bin/bleedingtooth-exploit`) | `/usr/local/share/atomos/bleedingtooth/` | Builds/runs BleedingTooth PoC (`exploit.c`) on first run. |
| BleedingTooth readme | `bleedingtooth-readme` | `/usr/local/bin/bleedingtooth-readme` (symlink: `/usr/bin/bleedingtooth-readme`) | `/usr/local/share/atomos/bleedingtooth/readme.md` | Prints local BleedingTooth usage notes. |
| Bluebugger | `bluebugger` | `/usr/local/bin/bluebugger` (symlink: `/usr/bin/bluebugger`) | `/usr/local/share/atomos/bluebugger/` | Builds/runs bluebugging script wrapper. |
| Bluesploit | `bluesploit` | `/usr/local/bin/bluesploit` (symlink: `/usr/bin/bluesploit`) | `/usr/local/share/atomos/bluesploit/` | Metasploit-style Bluetooth framework CLI. |
| BlueSpy | `bluespy` | `/usr/local/bin/bluespy` (symlink: `/usr/bin/bluespy`) | `/usr/local/share/atomos/bluespy/` | PoC to pair/connect/record audio from vulnerable devices. |
| btlejack | `btlejack` | `/usr/local/bin/btlejack` (symlink: `/usr/bin/btlejack`) | `/usr/local/share/atomos/btlejack/` | BLE sniffer/jam/hijack CLI for Micro:Bit-class hardware. |
| BLEeding | `bleeding` | `/usr/local/bin/bleeding` (symlink: `/usr/bin/bleeding`) | `/usr/local/share/atomos/bleeding/` | BR/EDR + BLE deauth/flood and scan tool. |

## Notes

- Many tools are source-installed and rely on runtime dependencies being available on-device.
- Some tools compile binaries on first run (`bluebugger`, `bleedingtooth-exploit`).
- `btle-python` is a helper launcher; available scripts are in `/usr/local/share/atomos/btle/python/`.
- `BTLE` C SDR utilities are source-only in image by default and can be built from `/usr/local/share/atomos/btle/host/`.
