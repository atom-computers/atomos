use core::alloc::{GlobalAlloc, Layout};

const HEAP_SIZE: usize = 256 * 1024;

static mut HEAP: [u8; HEAP_SIZE] = [0; HEAP_SIZE];
static mut HEAP_POS: usize = 0;

pub fn heap_pos() -> usize {
    unsafe { core::ptr::read_volatile(&raw const HEAP_POS) }
}

struct BumpAllocator;

unsafe impl GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pos = core::ptr::read_volatile(&raw const HEAP_POS);
        let align = layout.align();
        let aligned = (pos + align - 1) & !(align - 1);
        let next = aligned + layout.size();
        if next > HEAP_SIZE {
            return core::ptr::null_mut();
        }
        core::ptr::write_volatile(&raw mut HEAP_POS, next);
        unsafe { (&raw const HEAP).cast::<u8>().add(aligned) as *mut u8 }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}
}

#[global_allocator]
static ALLOCATOR: BumpAllocator = BumpAllocator;
