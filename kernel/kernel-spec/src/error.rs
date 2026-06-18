use core::fmt;

/// Errors returned by kernel operations.
///
/// Each variant maps to a class of failure. The exact semantics depend on
/// the operation — see the individual methods on [`Kernel`](crate::Kernel).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KernelError {
    /// The requested resource (region or process) does not exist.
    NotFound,
    /// The calling process lacks the required capability for this operation.
    AccessDenied,
    /// The requested memory or storage could not be allocated.
    OutOfMemory,
    /// One or more arguments to the operation were invalid.
    InvalidArgument,
    /// The resource being created already exists.
    AlreadyExists,
    /// The operation would block and non-blocking mode was requested.
    WouldBlock,
    /// The operation is not supported by this kernel implementation.
    NotSupported,
}

impl fmt::Display for KernelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KernelError::NotFound => write!(f, "resource not found"),
            KernelError::AccessDenied => write!(f, "access denied"),
            KernelError::OutOfMemory => write!(f, "out of memory"),
            KernelError::InvalidArgument => write!(f, "invalid argument"),
            KernelError::AlreadyExists => write!(f, "already exists"),
            KernelError::WouldBlock => write!(f, "operation would block"),
            KernelError::NotSupported => write!(f, "not supported"),
        }
    }
}
