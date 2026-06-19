use core::ptr::NonNull;
use virtio_drivers::{BufferDirection, Hal, PhysAddr};

use crate::memory::PageAlloc;

static mut DMA_ALLOC: *const PageAlloc = core::ptr::null();

pub fn init_dma_alloc(pa: &PageAlloc) {
    unsafe { DMA_ALLOC = pa as *const PageAlloc; }
}

fn page_alloc() -> &'static PageAlloc {
    unsafe { &*DMA_ALLOC }
}

pub struct VirtioHal;

unsafe impl Hal for VirtioHal {
    fn dma_alloc(
        pages: usize,
        _direction: BufferDirection,
        _access_platform: bool,
    ) -> (PhysAddr, NonNull<u8>) {
        let rounded = pages.next_power_of_two().max(1);
        let pa = page_alloc().alloc_pages(rounded) as PhysAddr;
        if pa == 0 {
            panic!("virtio dma_alloc: out of memory");
        }
        let va = NonNull::new(pa as *mut u8).expect("null dma pointer");
        unsafe {
            core::ptr::write_bytes(va.as_ptr(), 0, rounded * 4096);
        }
        (pa, va)
    }

    unsafe fn dma_dealloc(
        _paddr: PhysAddr,
        _vaddr: NonNull<u8>,
        _pages: usize,
        _access_platform: bool,
    ) -> i32 {
        0
    }

    unsafe fn mmio_phys_to_virt(paddr: PhysAddr, _size: usize) -> NonNull<u8> {
        NonNull::new(paddr as *mut u8).expect("null mmio pointer")
    }

    unsafe fn share(
        buffer: NonNull<[u8]>,
        _direction: BufferDirection,
        _access_platform: bool,
    ) -> PhysAddr {
        buffer.as_ptr() as *mut u8 as PhysAddr
    }

    unsafe fn unshare(
        _paddr: PhysAddr,
        _buffer: NonNull<[u8]>,
        _direction: BufferDirection,
        _access_platform: bool,
    ) {}
}
