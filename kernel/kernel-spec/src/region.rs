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
///
/// The kernel does not impose any semantic interpretation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElementFormat {
    /// 4 bytes per element: four unsigned 8-bit components.
    ///
    /// Use this for **display** regions — the four components map to
    /// color channels (the hardware driver defines which byte maps to
    /// R, G, B, or A).
    U8x4,
    /// 16 bytes per element: four 32-bit float components.
    ///
    /// Use this for **quantum state** regions (real + imaginary pairs
    /// or density-matrix entries) and **neural sensing** regions
    /// (signal amplitude, phase, coherence, and quality per channel).
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
    /// Unstructured bytes. The universal fallback.
    Raw,

    /// An abstract N-dimensional volume of data with spatial and temporal
    /// extents. Models any grid-shaped dataset that changes over time.
    ///
    /// # Implementations
    ///
    /// - **Display**: `z = 1`, `t` is the framebuffer generation.
    ///   The compositor writes pixel data each frame; the hardware scans out
    ///   the current slice at `t = current_frame`. U8x4 is suitable for
    ///   RGBA pixels.
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

    /// A stream of input events pushed into the region by hardware or
    /// another process. Consumption is up to the reader.
    InputStream,

    /// A bidirectional stream of network data. The read end receives
    /// incoming packets; the write end sends outgoing packets.
    NetworkStream,
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
    /// The kind of data this region holds.
    pub kind: RegionKind,
    /// Total allocated size in bytes.
    pub size: usize,
    /// Where the data currently resides in the memory hierarchy.
    pub tier: MemoryTier,
    /// Current access control flags.
    pub flags: RegionFlags,
}
