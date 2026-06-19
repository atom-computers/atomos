use core::ptr::NonNull;
use virtio_drivers::device::gpu::VirtIOGpu;
use virtio_drivers::transport::mmio::{MmioTransport, VirtIOHeader};

use crate::virtio_hal::VirtioHal;

pub struct GpuDriver<'a> {
    pub width: u32,
    pub height: u32,
    pub fb_ptr: *mut u8,
    pub fb_size: usize,
    pub(crate) gpu: VirtIOGpu<VirtioHal, MmioTransport<'a>>,
}

impl<'a> GpuDriver<'a> {
    pub fn init(base: u64, mmio_size: u64) -> Option<Self> {
        crate::println!("  gpu: creating MmioTransport...");
        let header = NonNull::new(base as *mut VirtIOHeader)?;
        let transport = unsafe { MmioTransport::new(header, mmio_size as usize) }.ok()?;
        crate::println!("  gpu: creating VirtIOGpu...");
        let mut gpu = VirtIOGpu::new(transport).ok()?;

        crate::println!("  gpu: setting up framebuffer...");
        let fb = gpu.setup_framebuffer().expect("virtio-gpu: framebuffer failed");
        let fb_size = fb.len();
        crate::println!("  gpu: framebuffer ready, {} bytes", fb.len());

        let fb_ptr = fb.as_ptr() as *mut u8;

        let fb_pixels = fb_size / 4;
        let candidates = [(720, 1440), (1280, 800), (1024, 768), (1920, 1080)];
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
            .unwrap_or_else(|| {
                let w = 1024u32;
                (w, (fb_pixels / w as usize) as u32)
            });

        Some(GpuDriver {
            width,
            height,
            fb_ptr,
            fb_size,
            gpu,
        })
    }

    pub fn flush(&mut self) {
        crate::println!(
            "  gpu: flushing {}x{} fb=0x{:x}",
            self.width,
            self.height,
            self.fb_ptr as usize
        );
        self.gpu.flush().expect("virtio-gpu: flush failed");
        crate::println!("  gpu: flush ok");
    }

    /// Contract test: verify framebuffer writes and reads.
    /// Returns true if all assertions pass.
    pub fn test_contract(&self) -> bool {
        let mut ok = true;
        if self.fb_ptr.is_null() {
            crate::println!("  gpu_test: FAIL fb_ptr is null");
            return false;
        }
        if self.fb_size == 0 {
            crate::println!("  gpu_test: FAIL fb_size is 0");
            return false;
        }
        if self.width == 0 || self.height == 0 {
            crate::println!("  gpu_test: FAIL resolution is 0");
            return false;
        }
        let expected_pixels = self.width as usize * self.height as usize;
        if self.fb_size < expected_pixels * 4 {
            crate::println!(
                "  gpu_test: FAIL fb_size {} < {}*{}*4={}",
                self.fb_size, self.width, self.height, expected_pixels * 4
            );
            return false;
        }

        // Test 1: write known pattern at (0,0) and read back
        unsafe {
            *self.fb_ptr = 0x12;
            *self.fb_ptr.add(1) = 0x34;
            *self.fb_ptr.add(2) = 0x56;
            *self.fb_ptr.add(3) = 0x78;
        }
        let b0 = unsafe { *self.fb_ptr };
        let b1 = unsafe { *self.fb_ptr.add(1) };
        let b2 = unsafe { *self.fb_ptr.add(2) };
        let b3 = unsafe { *self.fb_ptr.add(3) };
        if b0 != 0x12 || b1 != 0x34 || b2 != 0x56 || b3 != 0x78 {
            crate::println!(
                "  gpu_test: FAIL readback (0,0) got {:02x} {:02x} {:02x} {:02x}",
                b0, b1, b2, b3
            );
            ok = false;
        } else {
            crate::println!("  gpu_test: PASS pixel write/read at (0,0)");
        }

        // Test 2: write at last row, last column
        let last_row = self.height - 1;
        let last_col = self.width - 1;
        let off = ((last_row as usize * self.width as usize + last_col as usize) * 4) as usize;
        if off + 4 <= self.fb_size {
            unsafe {
                *self.fb_ptr.add(off) = 0xAB;
                *self.fb_ptr.add(off + 1) = 0xCD;
                *self.fb_ptr.add(off + 2) = 0xEF;
                *self.fb_ptr.add(off + 3) = 0x01;
            }
            let b0 = unsafe { *self.fb_ptr.add(off) };
            let b1 = unsafe { *self.fb_ptr.add(off + 1) };
            let b2 = unsafe { *self.fb_ptr.add(off + 2) };
            let b3 = unsafe { *self.fb_ptr.add(off + 3) };
            if b0 != 0xAB || b1 != 0xCD || b2 != 0xEF || b3 != 0x01 {
                crate::println!(
                    "  gpu_test: FAIL readback ({},{}) offset {}",
                    last_col, last_row, off
                );
                ok = false;
            } else {
                crate::println!(
                    "  gpu_test: PASS pixel write/read at ({},{}) offset {}",
                    last_col, last_row, off
                );
            }
        }

        // Test 3: DMA memory was zeroed on allocation
        // Check first byte of second page (should still be zeroed unless overwritten)
        let page_size = 4096;
        if self.fb_size > page_size {
            // We wrote to (0,0) but not to page 1, so byte at offset 4096 should be 0
            let b = unsafe { *self.fb_ptr.add(page_size) };
            if b != 0 {
                crate::println!(
                    "  gpu_test: FAIL DMA zero check: byte at {} = {:02x}",
                    page_size, b
                );
                ok = false;
            } else {
                crate::println!(
                    "  gpu_test: PASS DMA zeroed at offset {}",
                    page_size
                );
            }
        }

        ok
    }

    /// Fill the framebuffer with white and draw a centered black rectangle.
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
                        *self.fb_ptr.add(off) = 0xFF;
                        *self.fb_ptr.add(off + 1) = 0xFF;
                        *self.fb_ptr.add(off + 2) = 0xFF;
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
        core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
        self.flush();
    }
}
