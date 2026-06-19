use core::ptr::read_volatile;

const VIRTIO_MMIO_MAGIC_VALUE: u32 = 0x000;
const VIRTIO_MMIO_DEVICE_ID: u32 = 0x008;

pub const DEVICE_ID_GPU: u32 = 16;
pub const DEVICE_ID_INPUT: u32 = 18;

pub struct VirtioDevice {
    pub device_id: u32,
}

/// Probe a virtio-mmio device at `base`.
pub fn probe(base: u64) -> Option<VirtioDevice> {
    let magic = unsafe {
        read_volatile((base + VIRTIO_MMIO_MAGIC_VALUE as u64) as *const u32)
    };
    if magic != 0x74726976 {
        return None;
    }

    let device_id = unsafe {
        read_volatile((base + VIRTIO_MMIO_DEVICE_ID as u64) as *const u32)
    };

    Some(VirtioDevice { device_id })
}

/// Check if a virtio-input device is a tablet (has absolute axes).
/// Used for quick pre-init classification.
pub fn is_tablet(base: u64) -> bool {
    unsafe {
        core::ptr::write_volatile((base + 0x100) as *mut u8, 0x03);
        core::ptr::write_volatile((base + 0x101) as *mut u8, 0);
    }
    let bits = unsafe {
        read_volatile((base + 0x108) as *const u32)
    };
    bits & 0x3 != 0
}

/// Check if a virtio-input device is a keyboard (has key events).
/// Used for quick pre-init classification.
pub fn is_keyboard(base: u64) -> bool {
    unsafe {
        core::ptr::write_volatile((base + 0x100) as *mut u8, 1);
        core::ptr::write_volatile((base + 0x101) as *mut u8, 0);
    }
    let bits = unsafe {
        read_volatile((base + 0x108) as *const u32)
    };
    bits != 0
}
