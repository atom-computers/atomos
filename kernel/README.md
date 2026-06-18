# kernel

A minimal, portable kernel spec where **everything is a region of data** and **processes are reactive math functions**.

## Philosophy

Traditional kernels distinguish between RAM and storage, files and memory, threads and signals.
This kernel discards those distinctions. There are only three primitives:

- **Regions** — named, typed, tiered blobs of bytes. A display framebuffer is a region.
  A neural sensor grid is a region. A quantum state representation is a region.
  There is no "filesystem" — data is just regions.

- **Processes** — pure math functions. A process declares input regions (what it reads
  and reacts to), output regions (what it writes), and private regions (its internal
  state). When a subscribed input region changes, the process wakes, computes, writes
  its outputs, and yields. No preemption, no threads, no signals — just dataflow.

- **Memory tiers** — `ShortTerm` (fast, volatile) and `LongTerm` (slow, persistent).
  A process decides which tier to use for each region and can migrate data at runtime.
  No distinction between "RAM" and "disk" — just two points on a memory hierarchy.

The spec is hardware-agnostic. It does not assume classical CPUs, RAM, or a von Neumann
architecture. It defines *what* operations exist, not *how* they are implemented.

## Core abstractions

### Region

```rust
pub struct Region {
    pub id: RegionId,
    pub kind: RegionKind,     // Raw | Spatial { x, y, z, t, format } | InputStream | NetworkStream
    pub size: usize,
    pub tier: MemoryTier,     // ShortTerm | LongTerm
    pub flags: RegionFlags,   // READ | WRITE | GROWABLE
}
```

### Spatial region (4D data volume)

A `Spatial` region is a grid of typed elements across three spatial axes and one
temporal axis. The kernel treats the contents as opaque — only the dimension bounds
and element byte size matter for allocation.

```rust
Spatial {
    x: u32,                    // elements along x-axis
    y: u32,                    // elements along y-axis
    z: u32,                    // elements along z-axis (1 for 2D displays)
    t: u32,                    // temporal frames/timesteps
    format: ElementFormat,     // U8x4 (display) or F32x4 (quantum, neural)
}
```

Three concrete implementation cases for the same abstraction:

| Case | x × y × z | t | Format | Meaning of 4 components |
|---|---|---|---|---|
| **Display** | pixel grid, z=1 | frame counter | `U8x4` | color channels (driver-defined byte order) |
| **Quantum state** | wavefunction discretization | observation timestep | `F32x4` | complex amplitudes or density-matrix entries |
| **Neural sensing** | sensor channel grid | sampling frame | `F32x4` | signal amplitude, phase, coherence, quality |

### Process

```rust
pub struct Process {
    pub program: RegionId,    // format-agnostic: machine code, WASM, FPGA bitstream, ...
    pub inputs: Vec<(RegionId, Access)>,   // subscribed to changes
    pub outputs: Vec<(RegionId, Access)>,  // writes activate subscribers
    pub private: Vec<RegionId>,            // internal state
}
```

### Kernel trait

The complete set of primitives a process may call:

```rust
pub trait Kernel {
    // Regions
    fn create_region(&self, kind, size, tier) -> Result<RegionId, KernelError>;
    fn destroy_region(&self, id) -> Result<(), KernelError>;
    fn resize_region(&self, id, new_size) -> Result<(), KernelError>;
    fn set_tier(&self, id, tier) -> Result<(), KernelError>;     // migrate ShortTerm ↔ LongTerm
    fn read_region(&self, id, offset, buf) -> Result<usize, KernelError>;
    fn write_region(&self, id, offset, data) -> Result<usize, KernelError>;
    fn region_info(&self, id) -> Result<Region, KernelError>;

    // Processes
    fn current_pid(&self) -> Result<ProcessId, KernelError>;
    fn spawn(&self, process) -> Result<ProcessId, KernelError>;
    fn kill(&self, id) -> Result<(), KernelError>;

    // Dynamic subscriptions
    fn subscribe(&self, pid, region, access) -> Result<(), KernelError>;
    fn unsubscribe(&self, pid, region) -> Result<(), KernelError>;

    // Capabilities
    fn grant(&self, pid, region, access) -> Result<(), KernelError>;
    fn revoke(&self, pid, region) -> Result<(), KernelError>;
}
```

## Reactivity model

1. A process is spawned → activates immediately (initial run).
2. Any `write_region` call → all other processes subscribed to that region are
   scheduled for activation. The writer itself is not re-activated.
3. Subscriptions can be changed at runtime via `subscribe` / `unsubscribe`.
4. A process runs its computation, yields, and only wakes again when an input changes.
5. No preemption, no threads, no scheduling priorities — just dataflow-driven activation.

## Project structure

```
kernel/
├── Cargo.toml              # workspace root
├── kernel-spec/            # the portable spec (no_std)
│   └── src/
│       ├── region.rs       # RegionId, MemoryTier, ElementFormat, RegionKind, Region
│       ├── process.rs      # ProcessId, Access, Process
│       ├── kernel.rs       # Kernel trait (the spec)
│       ├── error.rs        # KernelError
│       └── lib.rs
├── kernel-mock/            # in-memory mock implementation (runs on host)
│   └── src/
│       ├── mock_kernel.rs  # MockKernel with Vec<u8> regions and closure-based processes
│       ├── demo.rs         # reactive dataflow test: two processes via shared regions
│       └── lib.rs
└── .gitignore
```

## Building & testing

```sh
cd kernel

# Build everything
cargo build

# Run the reactive dataflow demo
cargo test -- --nocapture
```

The mock kernel implements the full `Kernel` trait in-memory on the host machine.
It can run any process logic expressed as a Rust closure, enabling full testing of
the spec without hardware.

## Roadmap

- [x] Hardware-agnostic spec (`Kernel` trait)
- [x] Mock implementation with reactive dataflow demo
- [ ] AArch64 bare-metal implementation
- [ ] Display driver (Spatial region → physical framebuffer)
- [ ] Input driver (keyboard/touch → InputStream region)
- [ ] Code loading (spawn processes from ELF/WASM regions)
- [ ] Persistence layer (LongTerm tier backed by flash/storage)
