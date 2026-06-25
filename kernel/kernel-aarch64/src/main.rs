#![no_std]
#![no_main]

extern crate alloc;

mod uart;
mod panic;
mod allocator;
mod memory;
mod region;
mod kernel;
mod fdt;
mod virtio;
mod virtio_hal;
mod gpu;
mod pci;
mod input;
mod logger;

use core::arch::global_asm;
use kernel_spec::Kernel;

global_asm!(include_str!("start.s"));

#[unsafe(no_mangle)]
pub extern "C" fn kernel_main(fdt: *const u8) -> ! {
    uart::init();
    logger::init();
    println!("kernel-aarch64 booted");

    let k = kernel::Aarch64Kernel::new();
    virtio_hal::init_dma_alloc(k.page_allocator());
    k.quick_test();

    // Try PCI GPU first (works on macOS/Cocoa), fall back to MMIO
    let mut pci_gpu: Option<pci::PciGpu> = None;
    let mut gpu_opt: Option<gpu::GpuDriver> = None;
    let mut keyboard_opt: Option<input::InputDriver> = None;
    let mut tablet_opt: Option<input::InputDriver> = None;

    // Find PCIe host bridge from FDT to get ECAM base
    if let Some(reader) = fdt::FdtReader::new(fdt) {
        reader.walk(&|name: &str, addr: u64, _size: u64| {
            // Look for pci-host-ecam-generic or pci-host-cam-generic nodes
            if name.contains("pci") {
                crate::println!("  fdt: PCI node '{}' at 0x{:x}", name, addr);
                pci::set_ecam_base(addr);
            }
        });
    }

    if pci::has_ecam() {
        if let Some(pci) = pci::PciGpu::probe() {
            crate::println!("gpu: PCI GPU found {}x{} fb=0x{:x}", pci.width, pci.height, pci.fb_ptr as usize);
            pci_gpu = Some(pci);
        }
    }

    if let Some(reader) = fdt::FdtReader::new(fdt) {
        let gpu_addr = core::cell::Cell::new(0u64);
        let input_addrs = core::cell::RefCell::new(alloc::vec::Vec::new());

        reader.walk(&|_name: &str, addr: u64, _size: u64| {
            if let Some(dev) = virtio::probe(addr) {
                if dev.device_id == virtio::DEVICE_ID_GPU {
                    gpu_addr.set(addr);
                } else if dev.device_id == virtio::DEVICE_ID_INPUT {
                    input_addrs.borrow_mut().push(addr);
                    crate::println!("  fdt: input device at 0x{:x}", addr);
                }
            }
        });

        // Only init MMIO GPU if PCI GPU not found
        if pci_gpu.is_none() {
            let ga = gpu_addr.get();
            if ga != 0 {
                if let Some(gpu) = gpu::GpuDriver::init(ga, 0x1000) {
                    gpu_opt = Some(gpu);
                }
            }
        }

        for addr in input_addrs.borrow().iter() {
            if let Some(driver) =
                input::InputDriver::init(*addr, 0x1000, &k)
            {
                match &driver.kind {
                    input::InputKind::Keyboard(_) if keyboard_opt.is_none() => {
                        keyboard_opt = Some(driver);
                    }
                    input::InputKind::Tablet(_) if tablet_opt.is_none() => {
                        tablet_opt = Some(driver);
                    }
                    _ => {}
                }
            }
        }
    }

    // GPU contract tests
    if let Some(ref gpu) = gpu_opt {
        crate::println!("gpu: running contract tests...");
        if gpu.test_contract() {
            crate::println!("gpu: contract tests PASSED");
        } else {
            crate::println!("gpu: contract tests FAILED");
        }
    }

    // GPU render
    if let Some(ref mut gpu) = pci_gpu {
        println!(
            "kernel: GPU {}x{} fb=0x{:x}",
            gpu.width,
            gpu.height,
            gpu.fb_ptr as usize
        );
        gpu.render_preview();
        println!("kernel: GPU preview rendered!");
    } else if let Some(ref mut gpu) = gpu_opt {
        println!(
            "kernel: GPU {}x{} fb=0x{:x}",
            gpu.width,
            gpu.height,
            gpu.fb_ptr as usize
        );
        gpu.render_preview();
        println!("kernel: GPU preview rendered!");
    }

    // End-to-end test: keyboard input -> process -> display
    if let Some(ref keyboard) = keyboard_opt {
        run_e2e_test(&k, keyboard);
    }

    // Polling loop for input events
    loop {
        if let Some(ref mut kbd) = keyboard_opt {
            kbd.poll(&k);
        }
        if let Some(ref mut tbl) = tablet_opt {
            tbl.poll(&k);
        }
        core::hint::spin_loop();
    }
}

fn run_e2e_test(k: &kernel::Aarch64Kernel, input: &input::InputDriver) {
    crate::println!("input: running e2e subscription test...");

    let input::InputKind::Keyboard(keyboard_region_id) = input.kind else {
        return;
    };

    // Create a program region (empty dummy)
    let prog = k
        .create_region(
            kernel_spec::RegionKind::Raw,
            0,
            kernel_spec::MemoryTier::ShortTerm,
            Some("e2e-prog"),
        )
        .expect("e2e: create program region");

    let process = k
        .spawn(kernel_spec::Process {
            label: Some("keyboard-subscriber".into()),
            program: prog,
            inputs: alloc::vec![(keyboard_region_id, kernel_spec::Access::ReadOnly)],
            outputs: alloc::vec![],
            private: alloc::vec![],
        })
        .expect("e2e: spawn subscriber");

    k.subscribe(process, keyboard_region_id, kernel_spec::Access::ReadOnly)
        .expect("e2e: subscribe to keyboard");

    // Simulate a hardware key event by writing directly to the keyboard region
    // Scancode 30 = key 'a', value 1 = press
    k.write_region(keyboard_region_id, 30 * 4, &[1, 0, 0, 0])
        .expect("e2e: simulate key press");

    crate::println!("input: subscriber activated (pid={:?})", process);
}
