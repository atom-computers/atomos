use crate::{Access, KernelError, MemoryTier, Process, ProcessId, Region, RegionId, RegionKind, TrustDomain};

/// The kernel interface — the complete set of primitives a process may call
/// to interact with the system.
///
/// # Design philosophy
///
/// This trait is the **hardware-agnostic spec** for the kernel. It defines
/// *what* operations exist, but not *how* they are implemented. The same
/// trait can be backed by:
///
/// - A mock kernel running on the host (testing)
/// - A bare-metal kernel on AArch64
/// - A runtime on a quantum computer
/// - A distributed scheduler across a cluster
///
/// # Regions
///
/// Regions are the universal data primitive — there are no files, no
/// distinction between RAM and storage. Everything is a named, typed,
/// tiered blob of bytes of one of two kinds:
///
/// - [`RegionKind::Raw`] — unstructured bytes, the universal fallback.
/// - [`RegionKind::Spatial`] — a structured (x, y, z, t) grid of typed
///   elements. Used for displays, touch input, quantum states, and
///   neural sensor grids alike.
///
/// The distinction between "input" and "output" does not exist in the
/// type system — it is determined by which process holds write access.
///
/// # Processes
///
/// Processes are reactive math functions. They activate when an input
/// region changes, compute, write outputs, and yield. There is no
/// preemption, no signals, no threads — just dataflow-driven activation.
///
/// # Capabilities
///
/// Access to regions is mediated by capabilities. A process may only
/// operate on regions it has been granted access to.
pub trait Kernel {
    /// Allocate a new region of the given kind, size, and memory tier.
    ///
    /// The kernel assigns a unique [`RegionId`] and reserves `size` bytes
    /// of backing storage in the requested tier.
    ///
    /// `label` is an optional human-readable name to identify this region
    /// in debug output and kernel introspection.
    ///
    /// # Errors
    ///
    /// - `OutOfMemory` if the tier's backing storage is exhausted.
    fn create_region(
        &self,
        kind: RegionKind,
        size: usize,
        tier: MemoryTier,
        label: Option<&str>,
    ) -> Result<RegionId, KernelError>;

    /// Deallocate a region and release its backing storage.
    ///
    /// All capabilities to this region held by any process become invalid.
    /// Subscriptions on this region are dropped.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    fn destroy_region(&self, id: RegionId) -> Result<(), KernelError>;

    /// Change the allocated size of a growable region.
    ///
    /// The region must have the [`RegionFlags::GROWABLE`] flag set.
    /// Shrinking truncates data; growing zero-fills the new tail.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `NotSupported` if the region is not growable.
    /// - `OutOfMemory` if growing exceeds available storage.
    fn resize_region(&self, id: RegionId, new_size: usize) -> Result<(), KernelError>;

    /// Migrate a region's data between memory tiers.
    ///
    /// Moving from `ShortTerm` to `LongTerm` persists the data (on
    /// hardware that supports persistence). Moving from `LongTerm` to
    /// `ShortTerm` brings data into fast memory for active use.
    ///
    /// A no-op if the region is already in the requested tier.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `OutOfMemory` if the target tier cannot accommodate the region.
    fn set_tier(&self, id: RegionId, tier: MemoryTier) -> Result<(), KernelError>;

    /// Read bytes from a region at the given offset.
    ///
    /// Returns the number of bytes actually read, which may be less than
    /// `buf.len()` if the read extends past the end of the region.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `AccessDenied` if the calling process lacks `ReadOnly` access.
    fn read_region(
        &self,
        id: RegionId,
        offset: usize,
        buf: &mut [u8],
    ) -> Result<usize, KernelError>;

    /// Write bytes to a region at the given offset.
    ///
    /// After writing, any processes subscribed to this region (other than
    /// the writer itself) are scheduled for activation. This is the
    /// mechanism that drives the reactive dataflow model.
    ///
    /// Returns the number of bytes actually written.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `AccessDenied` if the calling process lacks `ReadWrite` access.
    fn write_region(
        &self,
        id: RegionId,
        offset: usize,
        data: &[u8],
    ) -> Result<usize, KernelError>;

    /// Return the metadata for a region.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    fn region_info(&self, id: RegionId) -> Result<Region, KernelError>;

    /// Return the [`ProcessId`] of the currently executing process.
    ///
    /// Useful for self-referential operations like `kill(current_pid())`.
    ///
    /// # Errors
    ///
    /// - `NotFound` if called outside of process context.
    fn current_pid(&self) -> Result<ProcessId, KernelError>;

    /// Create a new process from the given descriptor.
    ///
    /// The process is activated immediately after creation (it runs once
    /// on its initial inputs). It is then re-activated whenever any of its
    /// subscribed regions are written to.
    ///
    /// # Errors
    ///
    /// - `InvalidArgument` if any referenced region does not exist.
    /// - `OutOfMemory` if the kernel cannot allocate process state.
    fn spawn(&self, process: Process) -> Result<ProcessId, KernelError>;

    /// Terminate a process and clean up its resources.
    ///
    /// The process's private regions are destroyed. Its capabilities are
    /// revoked. Subscribers on its output regions are notified one final
    /// time.
    ///
    /// A process may kill itself: `kernel.kill(kernel.current_pid()?)`.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process does not exist.
    fn kill(&self, id: ProcessId) -> Result<(), KernelError>;

    /// Subscribe a process to changes on a region.
    ///
    /// After subscribing, the process will be activated whenever another
    /// process writes to the region. A process can subscribe to additional
    /// regions at runtime (beyond those declared in its `inputs` at spawn).
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process or region does not exist.
    fn subscribe(
        &self,
        pid: ProcessId,
        region: RegionId,
        access: Access,
    ) -> Result<(), KernelError>;

    /// Remove a process's subscription to a region.
    ///
    /// The process will no longer be activated when the region is written to.
    /// Its access to the region is not affected (use [`revoke`](Kernel::revoke) for that).
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process does not exist.
    fn unsubscribe(&self, pid: ProcessId, region: RegionId) -> Result<(), KernelError>;

    /// Grant a process access to a region.
    ///
    /// The grantor must already hold the same or greater access on the region.
    /// This is the basis of the capability security model: processes can only
    /// operate on regions they have been explicitly granted access to.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process or region does not exist.
    /// - `AccessDenied` if the grantor lacks sufficient access to delegate.
    fn grant(
        &self,
        pid: ProcessId,
        region: RegionId,
        access: Access,
    ) -> Result<(), KernelError>;

    /// Revoke a process's access to a region.
    ///
    /// After revocation, any attempt to read or write the region will
    /// fail with `AccessDenied`. Subscriptions on the region are also
    /// removed.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process or region does not exist.
    fn revoke(&self, pid: ProcessId, region: RegionId) -> Result<(), KernelError>;

    /// Rotate the master encryption key for a region.
    ///
    /// Generates a new master key, re-encrypts all region pages,
    /// derives new per-process keys for every process holding access,
    /// and securely zeroes the old master key.
    ///
    /// Only valid for regions with [`crate::RegionFlags::ENCRYPTED`].
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `NotSupported` if the region is not encrypted.
    fn rotate_region_key(&self, id: RegionId) -> Result<(), KernelError>;

    /// Map the process's authorized regions into its address space
    /// and prepare it for execution.
    ///
    /// On hardware with MMU support, this loads the process's page tables
    /// into TTBR0 and flushes stale TLB entries.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process does not exist.
    fn activate_process(&self, pid: ProcessId) -> Result<(), KernelError>;

    /// Flush the process's address space mappings and clear TTBR0.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the process does not exist.
    fn deactivate_process(&self, pid: ProcessId) -> Result<(), KernelError>;

    /// Authorize cross-domain data transfer for a region.
    ///
    /// Required before granting a region from one [`TrustDomain`] to another.
    /// The `vault_token` must be a valid signature from the Vault process
    /// authorizing the specific (region, from_domain, to_domain) triple.
    ///
    /// # Errors
    ///
    /// - `NotFound` if the region does not exist.
    /// - `AccessDenied` if the vault token is invalid or missing.
    fn authorize_transfer(
        &self,
        region: RegionId,
        from: TrustDomain,
        to: TrustDomain,
        vault_token: &[u8],
    ) -> Result<(), KernelError>;

    /// Request the Vault process to sign a payload.
    ///
    /// The request is written to `request_region` (a Vault inbox),
    /// and the signed response is read from `response_region` (a Vault
    /// outbox) once the Vault activates.
    ///
    /// # Errors
    ///
    /// - `NotFound` if either region does not exist.
    /// - `AccessDenied` if the calling process lacks write access to
    ///   `request_region` or read access to `response_region`.
    fn vault_sign(
        &self,
        request_region: RegionId,
        response_region: RegionId,
    ) -> Result<(), KernelError>;
}
