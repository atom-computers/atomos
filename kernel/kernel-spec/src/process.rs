use core::fmt;

use crate::RegionId;

/// A globally unique identifier for a process.
///
/// Allocated by the kernel on [`Kernel::spawn`](crate::Kernel::spawn).
/// Used to reference a process for lifecycle and capability operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProcessId(pub u64);

impl fmt::Display for ProcessId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "process:{}", self.0)
    }
}

/// The access level a process holds on a region.
///
/// Part of the capability model: a process may only read or write a region
/// if it has been granted the corresponding access.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    /// The process may read the region's contents but not modify them.
    ReadOnly,
    /// The process may both read and write the region.
    ReadWrite,
}

/// A process descriptor submitted to the kernel at spawn time.
///
/// A process is a reactive computation: it activates when any of its
/// `inputs` regions change, reads from those inputs, computes a result,
/// and writes to its `outputs` regions (which in turn may wake other
/// processes).
///
/// # Fields
///
/// - `program`: a region containing the process's executable code.
///   The kernel does not interpret this region — it is format-agnostic.
///   The hardware-specific execution layer decides how to instantiate
///   the computation (machine code, WASM, FPGA bitstream, quantum circuit, etc.).
///
/// - `inputs`: regions the process reads from and subscribes to.
///   When any of these regions are written to (by another process or
///   hardware), the kernel schedules this process for activation.
///
/// - `outputs`: regions the process writes to.
///   Available for read-write access. Writes to these regions will
///   activate any other processes subscribed to them.
///
/// - `private`: regions accessible only by this process.
///   Used for internal state. No other process can read or write them
///   (unless explicitly granted via [`Kernel::grant`](crate::Kernel::grant)).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Process {
    /// Region containing the process's program (format-agnostic).
    pub program: RegionId,
    /// Regions this process reads from. Subscribes to change notifications.
    pub inputs: alloc::vec::Vec<(RegionId, Access)>,
    /// Regions this process writes to.
    pub outputs: alloc::vec::Vec<(RegionId, Access)>,
    /// Regions private to this process (internal state).
    pub private: alloc::vec::Vec<RegionId>,
}
