const PAGE_SIZE: usize = 4096;

/// Physical page allocator using a simple bump-allocate strategy.
///
/// Pages are allocated sequentially starting from the physical address
/// immediately after the kernel image. Never freed in this implementation
/// — a proper buddy allocator can replace this later.
pub struct PageAlloc {
    next_page: core::cell::Cell<u64>,
    ram_end: u64,
}

impl PageAlloc {
    pub const fn new(ram_end_pa: u64) -> Self {
        PageAlloc {
            next_page: core::cell::Cell::new(0),
            ram_end: ram_end_pa,
        }
    }

    /// Lazy-initialize: set the first allocation address to the page after the kernel image.
    pub fn init(&self) {
        let image_end = unsafe {
            unsafe extern "C" {
                static __image_end: u8;
            }
            &raw const __image_end as u64
        };
        let first_page = (image_end + PAGE_SIZE as u64 - 1) & !(PAGE_SIZE as u64 - 1);
        self.next_page.set(first_page);
    }

    /// Allocate `count` consecutive physical pages. Returns the physical address of the first page,
    /// or 0 if out of memory.
    pub fn alloc_pages(&self, count: usize) -> u64 {
        let size = count as u64 * PAGE_SIZE as u64;
        let addr = self.next_page.get();
        if addr + size > self.ram_end {
            return 0;
        }
        self.next_page.set(addr + size);
        addr
    }

    pub fn page_size(&self) -> usize {
        PAGE_SIZE
    }
}
