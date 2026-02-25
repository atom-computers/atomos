# Security Manager

## Overview
The **Security Manager** guards the central nervous system of Atom OS. It manages permissions for tools, prevents untrusted network and disk access, and manages internal service certificates.

## Responsibilities
- **Certificate Authority:** Generates and verifies certificates for mutual TLS across core services.
- **ATA Containers / Sandboxing:** Automatically spins up Kata runtime instances for unsafe operations, strictly defining filesystem mounts and network accessibility.
- **Approvals & Whitelisting:** Manages the `/etc/atomos/whitelist.toml` registry and enforces user approval before actions that mutate system state.

*Note: In development mode, `ATOMOS_DEV=1` circumvents strict Kata execution to speed up iteration.*
