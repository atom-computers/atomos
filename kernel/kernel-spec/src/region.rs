use core::fmt;

/// A globally unique identifier for a region of data.
///
/// Allocated by the kernel on [`Kernel::create_region`](crate::Kernel::create_region).
/// Opaque to processes — they only hold the id, not the backing storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RegionId(pub u64);

impl fmt::Display for RegionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "region:{}", self.0)
    }
}

/// The memory tier of a region — describes performance and persistence
/// semantics without prescribing the physical backing.
///
/// A process may hold regions in both tiers simultaneously and can migrate
/// data between them at runtime via [`Kernel::set_tier`](crate::Kernel::set_tier).
///
/// What "short-term" and "long-term" mean physically depends on the hardware:
/// on a classical machine, `ShortTerm` maps to RAM and `LongTerm` to disk/flash;
/// on a future substrate they could be superconducting loops vs DNA storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryTier {
    /// Fast, small-capacity, volatile memory. Data is lost on power-off
    /// unless explicitly persisted. Suitable for working data in active use.
    ShortTerm,
    /// Slow, large-capacity, durable memory. Data survives power cycles.
    /// Suitable for long-lived state and data that must outlast the process.
    LongTerm,
}

/// The byte layout of a single element within a [`RegionKind::Spatial`] region.
///
/// The kernel treats the format as opaque — only the byte size matters for
/// region allocation. What each component *means* depends entirely on the
/// hardware implementation:
///
/// - **Display**: the four components may be color channels (R, G, B, A)
///   with a driver-defined byte order.
/// - **Quantum state**: the four components may be complex amplitudes
///   (real + imaginary pairs) or density-matrix entries.
/// - **Neural sensing**: the four components may be signal amplitude,
///   phase, coherence, and quality metrics.
/// - **Touch input**: the four components may be (active, pressure,
///   contact_id, reserved).
/// - **Keyboard input**: the four u8 components may be (pressed,
///   repeat_count, modifiers, reserved).
/// - **DNA storage**: the four components may be the four nucleotide
///   bases (A, T, G, C) encoded as presence flags or quality scores
///   per base per position, or stored as `F32x4` for probabilistic
///   base-calling (probability of each base at that position).
///
/// The kernel does not impose any semantic interpretation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElementFormat {
    /// 4 bytes per element: four unsigned 8-bit components.
    ///
    /// Use this for **display** regions (color channels, driver-defined
    /// byte order), **keyboard input** regions (scancode state), and
    /// **DNA storage** regions (discrete base-calling: A, T, G, C
    /// encoded as per-base presence or quality scores).
    U8x4,
    /// 16 bytes per element: four 32-bit float components.
    ///
    /// Use this for **quantum state** regions (complex amplitudes),
    /// **neural sensing** regions (signal + metadata per channel),
    /// **touch input** regions (active, pressure, contact_id), and
    /// **DNA storage** regions (probabilistic base-calling: probability
    /// of each of the four bases at that position).
    F32x4,
}

impl ElementFormat {
    /// The size of one element in bytes.
    pub fn byte_size(self) -> usize {
        match self {
            ElementFormat::U8x4 => 4,
            ElementFormat::F32x4 => 16,
        }
    }
}

/// The kind of data a region holds.
///
/// Determines how the region is interpreted by hardware drivers and other
/// processes. The kernel itself does not interpret region data — it only
/// provides read/write access to raw bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegionKind {
    /// Unstructured bytes. The universal fallback for data that does not
    /// have a natural spatial interpretation — heap memory, GPU-optimized
    /// buffers, linear storage, or any byte blob.
    Raw,

    /// An abstract N-dimensional volume of data with spatial and temporal
    /// extents. Models any grid-shaped dataset that changes over time.
    ///
    /// # Implementations
    ///
    /// - **Display**: `z = 1`, `t` is the framebuffer generation.
    ///   The compositor writes pixel data each frame; the hardware scans out
    ///   the current slice at `t = current_frame`.
    ///
    /// - **Touch input**: same `x × y` dimensions as the display region.
    ///   Each element holds touch state at that coordinate: `(active, pressure,
    ///   contact_id, reserved)` stored as `F32x4`. The hardware driver writes
    ///   to this region; subscribing processes react to changes.
    ///
    /// - **Keyboard input**: `x = 256`, one element per scancode.
    ///   Each element holds key state: `(pressed, repeat_count, modifiers,
    ///   reserved)` stored as `U8x4`.
    ///
    /// - **Quantum state**: `x × y × z` is the spatial discretization of
    ///   a wavefunction or probability cloud. `t` indexes the observation
    ///   timestep. Amplitudes are stored as `F32x4` (real + imaginary or
    ///   density-matrix components).
    ///
    /// - **Neural sensing**: `x × y × z` is the spatial grid of sensor
    ///   channels — electrode arrays, MEG sensors, cortical columns, or
    ///   any discretized neural field. `t` indexes the sampling frame.
    ///   Each element holds the measured signal at that spatial point
    ///   (voltage, field strength, blood-oxygen level, etc.) stored as
    ///   `F32x4` (signal + metadata/quality channels).
    ///
    /// - **DNA storage**: `x` is the sequence length (base positions),
    ///   `y` is the strand or read index, `z` is the chromosome or sample
    ///   index, and `t` is the sequencing generation or synthesis cycle.
    ///   Each element holds the four-base encoding at that position.
    ///   For discrete base-calling, use `U8x4` where each byte signals
    ///   presence of A, T, G, or C. For probabilistic calling (e.g.
    ///   nanopore or PacBio), use `F32x4` where each float is the
    ///   confidence score for A, T, G, or C at that position.
    ///
    /// The kernel does not interpret the contents — it only knows the
    /// dimension bounds and element format so it can allocate the region.
    Spatial {
        /// Number of elements along the x-axis.
        x: u32,
        /// Number of elements along the y-axis.
        y: u32,
        /// Number of elements along the z-axis.
        ///
        /// For a traditional 2D display, this is `1`.
        z: u32,
        /// Number of temporal frames or timesteps.
        ///
        /// Allows time-indexed access: drivers or processes can read/write
        /// the state at a specific `t`, enabling animation buffers,
        /// double-buffering, or quantum trajectory snapshots.
        t: u32,
        /// The byte layout of each element in the spatial grid.
        format: ElementFormat,
    },
}

/// Access control flags for a region.
///
/// Combined with [`MemoryTier`], these determine what operations a process
/// may perform on a region.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RegionFlags {
    bits: u8,
}

impl RegionFlags {
    pub const READ: Self = RegionFlags { bits: 1 << 0 };
    pub const WRITE: Self = RegionFlags { bits: 1 << 1 };
    /// The region can grow or shrink via [`Kernel::resize_region`](crate::Kernel::resize_region).
    pub const GROWABLE: Self = RegionFlags { bits: 1 << 2 };
    /// Region contents are stored as AEAD ciphertext.
    /// Reads and writes transparently encrypt/decrypt using per-process
    /// derived keys. Without a key, reads return [`crate::KernelError::AccessDenied`].
    pub const ENCRYPTED: Self = RegionFlags { bits: 1 << 3 };
    /// Region is sealed after initial write; further writes are denied.
    /// Used for code regions (Harvard architecture: instruction memory
    /// is immutable after verification) and read-only data regions.
    pub const IMMUTABLE: Self = RegionFlags { bits: 1 << 4 };

    pub fn contains(self, other: RegionFlags) -> bool {
        (self.bits & other.bits) == other.bits
    }
}

impl core::ops::BitOr for RegionFlags {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        RegionFlags {
            bits: self.bits | rhs.bits,
        }
    }
}

impl core::ops::BitOrAssign for RegionFlags {
    fn bitor_assign(&mut self, rhs: Self) {
        self.bits |= rhs.bits;
    }
}

/// A snapshot of a region's metadata, returned by
/// [`Kernel::region_info`](crate::Kernel::region_info).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Region {
    /// The region's unique identifier.
    pub id: RegionId,
    /// Optional human-readable label for debugging and review.
    pub label: Option<alloc::string::String>,
    /// The kind of data this region holds.
    pub kind: RegionKind,
    /// Total allocated size in bytes.
    pub size: usize,
    /// Where the data currently resides in the memory hierarchy.
    pub tier: MemoryTier,
    /// Current access control flags.
    pub flags: RegionFlags,
}
