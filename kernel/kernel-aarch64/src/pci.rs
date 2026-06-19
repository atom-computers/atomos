use virtio_drivers::device::gpu::VirtIOGpu;
use virtio_drivers::transport::pci::{
    PciTransport,
    bus::{BarInfo, Cam, Command, ConfigurationAccess, DeviceFunction, MemoryBarType, MmioCam, PciRoot},
    virtio_device_type,
};

use crate::virtio_hal::VirtioHal;

/// Fallback ECAM base on QEMU aarch64 `virt` machine.
const ECAM_FALLBACK: usize = 0x3f000000;

/// ECAM base discovered from FDT, or fallback.
static mut ECAM_BASE: usize = 0;

pub fn set_ecam_base(addr: u64) {
    unsafe { ECAM_BASE = addr as usize; }
}

pub fn has_ecam() -> bool {
    unsafe { ECAM_BASE != 0 }
}

/// PCI variant of GPU driver using PciTransport.
pub struct PciGpu {
    pub width: u32,
    pub height: u32,
    pub fb_ptr: *mut u8,
    pub fb_size: usize,
    gpu: VirtIOGpu<VirtioHal, PciTransport>,
}

impl PciGpu {
    /// Probe PCI bus for a virtio-gpu and initialize it.
    pub fn probe() -> Option<Self> {
        let ecam = unsafe {
            if ECAM_BASE != 0 { ECAM_BASE } else { ECAM_FALLBACK }
        };
        crate::println!("  pci: scanning ECAM at 0x{:x}", ecam);

        crate::println!("  pci: creating MmioCam...");
        let cam = unsafe { MmioCam::new(ecam as *mut u8, Cam::Ecam) };
        crate::println!("  pci: creating PciRoot...");
        let mut pci_root = PciRoot::new(cam);
        crate::println!("  pci: enumerating bus 0...");

        for (device_function, info) in pci_root.enumerate_bus(0) {
            let Some(vt) = virtio_device_type(&info) else {
                continue;
            };
            // Only interested in GPU devices
            if vt != virtio_drivers::transport::DeviceType::GPU {
                crate::println!("  pci: skipping {:?} at {}", vt, device_function);
                continue;
            }
            crate::println!(
                "  pci: found {} at {}",
                info, device_function
            );

            allocate_bars(&mut pci_root, device_function);

            let transport = match PciTransport::new::<VirtioHal, _>(
                &mut pci_root,
                device_function,
            ) {
                Ok(t) => t,
                Err(_) => {
                    crate::println!("  pci: PciTransport::new failed");
                    continue;
                }
            };

            crate::println!("  pci: creating VirtIOGpu...");
            let mut gpu = match VirtIOGpu::new(transport) {
                Ok(g) => g,
                Err(_) => {
                    crate::println!("  pci: VirtIOGpu::new failed");
                    continue;
                }
            };

            crate::println!("  pci: setting up framebuffer...");
            let fb = match gpu.setup_framebuffer() {
                Ok(fb) => fb,
                Err(_) => {
                    crate::println!("  pci: setup_framebuffer failed");
                    continue;
                }
            };
            let fb_size = fb.len();
            crate::println!("  pci: framebuffer ready, {} bytes", fb_size);

            let fb_ptr = fb.as_ptr() as *mut u8;
            let fb_pixels = fb_size / 4;
            let candidates = [(720, 1440u32), (1280, 800), (1024, 768), (1920, 1080)];
            let (width, height) = candidates
                .iter()
                .find_map(|&(w, h)| {
                    let min = w as usize * h as usize;
                    let max = w as usize * (h as usize + 1);
                    if min <= fb_pixels && fb_pixels < max {
                        Some((w, h))
                    } else {
                        None
                    }
                })
                .unwrap_or((1024, (fb_pixels / 1024) as u32));

            return Some(PciGpu {
                width,
                height,
                fb_ptr,
                fb_size,
                gpu,
            });
        }

        crate::println!("  pci: no GPU found");
        None
    }

    pub fn flush(&mut self) {
        self.gpu.flush().expect("pci-gpu: flush failed");
    }

    pub fn render_preview(&mut self) {
        let rect_w = self.width * 6 / 10;
        let rect_h = self.height * 6 / 10;
        let rect_x = (self.width - rect_w) / 2;
        let rect_y = (self.height - rect_h) / 2;

        for y in 0..self.height {
            for x in 0..self.width {
                let off = ((y * self.width + x) * 4) as usize;
                let is_rect = x >= rect_x
                    && x < rect_x + rect_w
                    && y >= rect_y
                    && y < rect_y + rect_h;
                if is_rect {
                    unsafe {
                        *self.fb_ptr.add(off) = 0x00;
                        *self.fb_ptr.add(off + 1) = 0x00;
                        *self.fb_ptr.add(off + 2) = 0x00;
                        *self.fb_ptr.add(off + 3) = 0xFF;
                    }
                } else {
                    unsafe {
                        *self.fb_ptr.add(off) = 0xFF;
                        *self.fb_ptr.add(off + 1) = 0xFF;
                        *self.fb_ptr.add(off + 2) = 0xFF;
                        *self.fb_ptr.add(off + 3) = 0xFF;
                    }
                }
            }
        }
        // Memory barrier: ensure all fb writes visible to DMA
        core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
        self.flush();
        // Busy-wait to give QEMU display backend time to render
        for _ in 0..50000000 {
            core::hint::spin_loop();
        }
        // Memory barrier: ensure writes visible before re-flush
        core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
        self.flush();
    }
}

fn allocate_bars(root: &mut PciRoot<impl ConfigurationAccess>, device_function: DeviceFunction) {
    // Separate allocators for 32-bit and 64-bit BARs
    let mut next_32: u32 = 0x1000_0000; // MMIO32 window
    let mut next_64: u64 = 0x80_0000_0000; // MMIO64 window

    for (bar_index, info) in root.bars(device_function).unwrap().into_iter().enumerate() {
        let Some(info) = info else { continue };
        if let BarInfo::Memory {
            address_type, size, ..
        } = info
        {
            let bar_size = size;
            if bar_size == 0 {
                continue;
            }

            match address_type {
                MemoryBarType::Width32 => {
                    let aligned = (next_32 as u64 + bar_size - 1) & !(bar_size - 1);
                    let addr = aligned as u32;
                    root.set_bar_32(device_function, bar_index as u8, addr);
                    crate::println!(
                        "  pci: BAR{} (32-bit) -> 0x{:x} (size {})",
                        bar_index, addr, bar_size
                    );
                    next_32 = addr + bar_size as u32;
                }
                MemoryBarType::Width64 => {
                    let aligned = (next_64 + bar_size - 1) & !(bar_size - 1);
                    root.set_bar_64(device_function, bar_index as u8, aligned);
                    crate::println!(
                        "  pci: BAR{} (64-bit) -> 0x{:x} (size {})",
                        bar_index, aligned, bar_size
                    );
                    next_64 = aligned + bar_size;
                }
                _ => continue,
            }
        }
    }

    // Enable bus mastering and memory space
    root.set_command(
        device_function,
        Command::IO_SPACE | Command::MEMORY_SPACE | Command::BUS_MASTER,
    );
}
