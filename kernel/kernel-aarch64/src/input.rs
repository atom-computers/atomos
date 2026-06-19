extern crate alloc;

use core::ptr::NonNull;
use virtio_drivers::device::input::{InputEvent, VirtIOInput};
use virtio_drivers::transport::mmio::{MmioTransport, VirtIOHeader};

use kernel_spec::{ElementFormat, Kernel, MemoryTier, RegionId, RegionKind};

use crate::kernel::Aarch64Kernel;
use crate::virtio_hal::VirtioHal;

pub enum InputKind {
    Keyboard(RegionId),
    Tablet(RegionId),
}

pub struct InputDriver<'a> {
    pub kind: InputKind,
    input: VirtIOInput<VirtioHal, MmioTransport<'a>>,
}

impl<'a> InputDriver<'a> {
    pub fn init(
        base: u64,
        mmio_size: u64,
        kernel: &Aarch64Kernel,
    ) -> Option<Self> {
        crate::println!("  input: creating MmioTransport at 0x{:x}...", base);
        let header = NonNull::new(base as *mut VirtIOHeader)?;
        let transport = unsafe { MmioTransport::new(header, mmio_size as usize) };
        let mut transport = match transport {
            Ok(t) => t,
            Err(e) => {
                crate::println!("  input: MmioTransport failed: {:?}", e);
                return None;
            }
        };
        crate::println!("  input: creating VirtIOInput...");
        let input = VirtIOInput::new(transport);
        let mut input = match input {
            Ok(i) => i,
            Err(e) => {
                crate::println!("  input: VirtIOInput::new failed: {:?}", e);
                return None;
            }
        };

        let name = input.name().unwrap_or_else(|_| alloc::string::String::from("unknown"));
        crate::println!("  input: device name: {}", name);

        let has_abs = input
            .ev_bits(0x03)
            .map(|b| !b.is_empty())
            .unwrap_or(false);

        if has_abs && !name.contains("Keyboard") {
            let data_size =
                720 * 1440 * 1 * 1 * ElementFormat::F32x4.byte_size();
            let region_id = kernel
                .create_region(
                    RegionKind::Spatial {
                        x: 720,
                        y: 1440,
                        z: 1,
                        t: 1,
                        format: ElementFormat::F32x4,
                    },
                    data_size,
                    MemoryTier::ShortTerm,
                    Some("tablet"),
                )
                .ok()?;
            crate::println!(
                "input: tablet driver initialized, tablet region {:?}, {} bytes, {}x{}x{}x{} F32x4",
                region_id, data_size, 720, 1440, 1, 1
            );
            Some(InputDriver {
                kind: InputKind::Tablet(region_id),
                input,
            })
        } else {
            let data_size =
                256 * 1 * 1 * ElementFormat::U8x4.byte_size();
            let region_id = kernel
                .create_region(
                    RegionKind::Spatial {
                        x: 256,
                        y: 1,
                        z: 1,
                        t: 1,
                        format: ElementFormat::U8x4,
                    },
                    data_size,
                    MemoryTier::ShortTerm,
                    Some("keyboard"),
                )
                .ok()?;
            crate::println!(
                "input: keyboard driver initialized, keyboard region {:?}, {} bytes, {}x{}x{}x{} U8x4",
                region_id, data_size, 256, 1, 1, 1
            );
            Some(InputDriver {
                kind: InputKind::Keyboard(region_id),
                input,
            })
        }
    }

    pub fn poll(&mut self, kernel: &Aarch64Kernel) {
        while let Some(event) = self.input.pop_pending_event() {
            match &self.kind {
                InputKind::Keyboard(region_id) => {
                    self.handle_keyboard_event(*region_id, kernel, &event);
                }
                InputKind::Tablet(region_id) => {
                    self.handle_tablet_event(*region_id, kernel, &event);
                }
            }
        }
    }

    fn handle_keyboard_event(
        &self,
        region_id: RegionId,
        kernel: &Aarch64Kernel,
        event: &InputEvent,
    ) {
        let scancode = event.code as u32;
        if event.event_type == 1 && scancode < 256 {
            let off = scancode as usize * 4;
            let data: [u8; 4] = if event.value > 0 {
                [1, 0, 0, 0]
            } else {
                [0, 0, 0, 0]
            };
            let _ = kernel.write_region(region_id, off, &data);
            crate::println!(
                "input: key event scancode={} value={}",
                scancode,
                event.value
            );
        }
    }

    fn handle_tablet_event(
        &self,
        region_id: RegionId,
        kernel: &Aarch64Kernel,
        event: &InputEvent,
    ) {
        if event.event_type == 3 {
            let (axis, value) = match event.code {
                0x00 => ("ABS_X", event.value),
                0x01 => ("ABS_Y", event.value),
                0x18 => ("ABS_PRESSURE", event.value),
                _ => return,
            };
            crate::println!(
                "input: tablet event axis={} value={}",
                axis,
                value
            );

            let offset = match event.code {
                0x00 => 0,
                0x01 => 16,
                0x18 => 32,
                _ => return,
            };
            let f32_bytes = (value as f32).to_le_bytes();
            let _ = kernel.write_region(region_id, offset, &f32_bytes);
        }
    }
}
