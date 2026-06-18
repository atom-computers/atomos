# Atom OS

Atom OS is a new cross-platform operating system built on a **custom Rust kernel** (`kernel/`). The kernel model replaces traditional OS abstractions — filesystems, threads, signals, RAM-vs-disk — with a single unified primitive: **regions of data** accessed by **reactive math functions** (processes). This design is portable beyond classical von Neumann architectures to quantum processors, neural interfaces, and future hardware.

The OS is a rethink of how computing should work in the modern age. It is designed to be AI-powered with a focus on a new age of computing. It is also built to be secure, fast and compact.

### Security advantages

- Over half of iOS exploits are due to memory corruption bugs. These are easier to prevent with a Rust-based foundation that uses formal verification on the kernel.

- The kernel uses a **capability-based security model**. Processes can only access regions they have been explicitly granted access to. Capabilities can be delegated and revoked at runtime.

- Each program is sandboxed and completely isolated from the main system itself.


### Cross-platform

- The OS is designed to run on ARM processors for desktop, mobile, servers and embedded devices.

### Intelligence

Atom OS is designed to be intelligent at the core of the user experience.

- Full context-aware history across your data using a new file-system based on memories and documents. [SurrealDB](https://surrealdb.com/) is used to automatically index and organize your data for AI agents.

- Use natural language to interact with your digital world and physical devices. See the full list of supported connections for MCP servers [here](https://github.com/modelcontextprotocol/servers?tab=readme-ov-file#-third-party-servers) and smart home devices [here](https://matter-smarthome.de/en/overview-products-compatible-with-matter/).

- AI automations can be spawned to perform tasks on your behalf across your digital world and physical devices.

- Generative UI enables agents to control the user interface. This means that you can collaboratively interact with your computer and AI hands free.


![Flow Diagram](docs/assets/FlowDiagram.gif)

### Use cases

- **Personal computing**

    Atom OS is intended for use in the [Atom 1](https://atomcomputers.org/) as a private offline AI-powered operating system.

- **Robotics**

    Keeping the robot's long-term memory on the robot itself instead of in the cloud to ensure privacy and security.

- **IoT & embedded devices**

    Making intelligent devices such as offline security camera monitoring systems, smart home devices, and more.

- **Servers**

    Businesses that want to connect their data and devices to an intelligent system they control for automation and analysis.

## Supported Architectures

The kernel spec is hardware-agnostic. The first target implementation is **aarch64**.

## Kernel

The kernel lives at [`kernel/`](kernel/) and is currently in the **hardware-agnostic spec** phase.
See the [kernel README](kernel/README.md) for the full design document.

### Build & test

```sh
cd kernel
cargo build
cargo test -- --nocapture
```

The mock kernel runs on the host machine with no hardware dependencies, enabling
rapid iteration and testing of the spec before targeting bare metal.