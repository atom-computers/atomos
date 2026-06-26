use core::arch::asm;

use crate::memory::PageAlloc;
use kernel_spec::{Access, MappingType};

const GRANULE: u64 = 12; // 4KB
const GRANULE_SIZE: usize = 1 << GRANULE;
const L_TABLE_ENTRIES: usize = 512;

// TCR_EL1 encoding
const TCR_T0SZ_48: u64 = (64 - 48) << 0;
const TCR_T1SZ_48: u64 = (64 - 48) << 16;
const TCR_TG0_4K: u64 = 0b00 << 14;
const TCR_TG1_4K: u64 = 0b10 << 30;
const TCR_SH0_INNER: u64 = 3 << 12;
const TCR_SH1_INNER: u64 = 3 << 28;
const TCR_ORGN0_WB: u64 = 1 << 10;
const TCR_IRGN0_WB: u64 = 1 << 8;
const TCR_ORGN1_WB: u64 = 1 << 26;
const TCR_IRGN1_WB: u64 = 1 << 24;

const TCR_EL1_VAL: u64 =
    TCR_T0SZ_48 | TCR_T1SZ_48 | TCR_TG0_4K | TCR_TG1_4K |
    TCR_SH0_INNER | TCR_SH1_INNER |
    TCR_ORGN0_WB | TCR_IRGN0_WB | TCR_ORGN1_WB | TCR_IRGN1_WB;

// MAIR memory types
const MAIR_ATTR_NORMAL_WB: u64 = 0xFF; // inner+outer WB, non-transient, RWA
const MAIR_ATTR_DEVICE: u64 = 0x00;    // Device-nGnRnE

const MAIR_EL1_VAL: u64 =
    (MAIR_ATTR_NORMAL_WB << 0) |
    (MAIR_ATTR_DEVICE << 8);

// Descriptor bits
const DESC_VALID_PAGE: u64 = 0b11;
const DESC_VALID_BLOCK: u64 = 0b01;
const DESC_VALID_TABLE: u64 = 0b11;

const UXN_BIT: u64 = 1 << 54;
const PXN_BIT: u64 = 1 << 53;
const AF_BIT: u64 = 1 << 10;
const NG_BIT: u64 = 1 << 11;
const NS_BIT: u64 = 1 << 5;

// Shareability
const SH_INNER: u64 = 3;

// Access permissions for stage 1 EL0
const AP_EL1_ONLY: u64 = 0b00;
const AP_EL0_RW: u64 = 0b01;
const AP_EL0_RO: u64 = 0b11;

const ATTR_NORMAL: u64 = 0; // MAIR index 0
const ATTR_DEVICE: u64 = 1; // MAIR index 1

fn table_va(phys: u64) -> *mut u64 {
    phys as *mut u64
}

fn alloc_table(page_alloc: &PageAlloc) -> u64 {
    let pa = page_alloc.alloc_pages(1);
    unsafe {
        core::ptr::write_bytes(table_va(pa), 0, GRANULE_SIZE);
    }
    pa
}

/// Kernel page table: identity-maps all RAM and devices into TTBR0.
pub struct KernelTables {
    pub ttbr0: u64,
}

impl KernelTables {
    pub fn init(page_alloc: &PageAlloc, _ram_base: u64, _ram_size: u64) -> Self {
        let l0 = alloc_table(page_alloc);
        let l1 = alloc_table(page_alloc);

        unsafe {
            (l0 as *mut u64).write_volatile(l1 | DESC_VALID_TABLE);
            let l1_ptr = l1 as *mut u64;

            // Map first 8GB using 1GB block descriptors at L1.
            // 0x00000000-0x3FFFFFFF: device (UART, virtio)
            // 0x40000000-0x7FFFFFFF: normal memory (RAM, kernel)
            // 0x80000000-0xBFFFFFFF: device (additional virtio)
            // 0xC0000000-0xFFFFFFFF: device
            // 0x100000000-0x13FFFFFFF: device
            // etc.
            for l1_idx in 0u64..512u64 {
                let gb = l1_idx << 30;
                let desc = if l1_idx == 1 {
                    // 0x40000000: normal memory
                    gb | DESC_VALID_BLOCK | (ATTR_NORMAL << 2) | SH_INNER << 8 | AF_BIT
                } else {
                    gb | DESC_VALID_BLOCK | (ATTR_DEVICE << 2) | AF_BIT
                };
                l1_ptr.add(l1_idx as usize).write_volatile(desc);
            }
        }

        KernelTables { ttbr0: l0 }
    }
}

pub struct ProcessPageTable {
    root: u64,
    ttbr0: u64,
}

impl ProcessPageTable {
    pub fn new(page_alloc: &PageAlloc, asid: u16) -> Self {
        let root = alloc_table(page_alloc);
        let ttbr0 = root | (asid as u64) << 48;
        ProcessPageTable { root, ttbr0 }
    }

    pub fn ttbr0(&self) -> u64 {
        self.ttbr0
    }

    pub fn map(
        &mut self,
        page_alloc: &PageAlloc,
        va: u64,
        pa: u64,
        pages: usize,
        map_type: MappingType,
        access: Access,
    ) {
        for i in 0..pages {
            self.map_page(page_alloc, va + i as u64 * GRANULE_SIZE as u64, pa + i as u64 * GRANULE_SIZE as u64, map_type, access);
        }
    }

    fn map_page(
        &mut self,
        page_alloc: &PageAlloc,
        va: u64,
        pa: u64,
        map_type: MappingType,
        access: Access,
    ) {
        let mut desc = pa | DESC_VALID_PAGE;

        match map_type {
            MappingType::Code => {
                // XN=0 (execute permitted), EL0 read-only, normal memory
                desc |= ATTR_NORMAL << 2;
                desc |= AF_BIT;
                // PXN=1 prevents EL1 execution too? No — we want kernel to be able
                // to read it. Code at EL0: R+execute, no write.
                desc |= AP_EL0_RO << 6;
            }
            MappingType::Data => {
                // XN=1 (no execute), AP per access level
                desc |= ATTR_NORMAL << 2;
                desc |= AF_BIT;
                desc |= UXN_BIT;
                desc |= PXN_BIT;
                let ap = match access {
                    Access::ReadOnly => AP_EL0_RO,
                    Access::ReadWrite => AP_EL0_RW,
                };
                desc |= ap << 6;
            }
            MappingType::Guard => {
                return; // just don't map — leave entry as 0 (fault)
            }
        }

        desc |= SH_INNER << 8;

        // Walk and populate page tables
        let l0_idx = ((va >> 39) & 0x1FF) as usize;
        let l1_idx = ((va >> 30) & 0x1FF) as usize;
        let l2_idx = ((va >> 21) & 0x1FF) as usize;
        let l3_idx = ((va >> 12) & 0x1FF) as usize;

        unsafe {
            let l0_ptr = self.root as *mut u64;
            let l0_entry = l0_ptr.add(l0_idx).read_volatile();
            let l1_pa = if l0_entry == 0 {
                let new_l1 = alloc_table(page_alloc);
                l0_ptr.add(l0_idx).write_volatile(new_l1 | DESC_VALID_TABLE);
                new_l1
            } else {
                l0_entry & 0x0000_FFFF_FFFF_F000
            };

            let l1_ptr = l1_pa as *mut u64;
            let l1_entry = l1_ptr.add(l1_idx).read_volatile();
            let l2_pa = if l1_entry == 0 {
                let new_l2 = alloc_table(page_alloc);
                l1_ptr.add(l1_idx).write_volatile(new_l2 | DESC_VALID_TABLE);
                new_l2
            } else {
                l1_entry & 0x0000_FFFF_FFFF_F000
            };

            let l2_ptr = l2_pa as *mut u64;
            let l2_entry = l2_ptr.add(l2_idx).read_volatile();
            let l3_pa = if l2_entry == 0 {
                let new_l3 = alloc_table(page_alloc);
                l2_ptr.add(l2_idx).write_volatile(new_l3 | DESC_VALID_TABLE);
                new_l3
            } else {
                l2_entry & 0x0000_FFFF_FFFF_F000
            };

            let l3_ptr = l3_pa as *mut u64;
            l3_ptr.add(l3_idx).write_volatile(desc);
        }
    }

    pub fn unmap(&mut self, va: u64, pages: usize) {
        for i in 0..pages {
            self.unmap_page(va + i as u64 * GRANULE_SIZE as u64);
        }
    }

    fn unmap_page(&mut self, va: u64) {
        let l0_idx = ((va >> 39) & 0x1FF) as usize;
        let l1_idx = ((va >> 30) & 0x1FF) as usize;
        let l2_idx = ((va >> 21) & 0x1FF) as usize;
        let l3_idx = ((va >> 12) & 0x1FF) as usize;

        unsafe {
            let l0_ptr = self.root as *mut u64;
            let l0_entry = l0_ptr.add(l0_idx).read_volatile();
            if l0_entry == 0 { return; }
            let l1_pa = l0_entry & 0x0000_FFFF_FFFF_F000;

            let l1_ptr = l1_pa as *mut u64;
            let l1_entry = l1_ptr.add(l1_idx).read_volatile();
            if l1_entry == 0 { return; }
            let l2_pa = l1_entry & 0x0000_FFFF_FFFF_F000;

            let l2_ptr = l2_pa as *mut u64;
            let l2_entry = l2_ptr.add(l2_idx).read_volatile();
            if l2_entry == 0 { return; }
            let l3_pa = l2_entry & 0x0000_FFFF_FFFF_F000;

            let l3_ptr = l3_pa as *mut u64;
            l3_ptr.add(l3_idx).write_volatile(0);
        }
    }
}

pub fn set_ttbr0(ttbr0: u64) {
    unsafe {
        asm!(
            "msr ttbr0_el1, {0}",
            "isb",
            in(reg) ttbr0,
        );
    }
}

pub fn set_mair_tcr() {
    let mair: u64 = MAIR_EL1_VAL;
    let tcr: u64 = TCR_EL1_VAL;
    unsafe {
        asm!(
            "msr mair_el1, {mair}",
            "msr tcr_el1, {tcr}",
            "isb",
            "tlbi vmalle1",
            "dsb ish",
            "isb",
            "ic ialluis",
            "dsb ish",
            "isb",
            mair = in(reg) mair,
            tcr = in(reg) tcr,
        );
    }
}

pub fn flush_and_enable_m_bit() {
    unsafe {
        // QEMU boots with I and C cache bits set. Disable them before MMU enable
        // to avoid stale cache entries confusing the initial translation.
        asm!(
            "mrs {r}, sctlr_el1",
            "bic {r}, {r}, #(1 << 2)",   // clear C
            "bic {r}, {r}, #(1 << 12)",  // clear I
            "msr sctlr_el1, {r}",
            "isb",
            r = out(reg) _,
        );
        // Now enable M bit
        asm!(
            "mrs {r}, sctlr_el1",
            "orr {r}, {r}, #1",
            "msr sctlr_el1, {r}",
            "isb",
            r = out(reg) _,
        );
    }
}

pub fn enable_c_bit() {
    unsafe {
        asm!(
            "mrs {r}, sctlr_el1",
            "orr {r}, {r}, #(1 << 2)",
            "msr sctlr_el1, {r}",
            "isb",
            r = out(reg) _,
        );
    }
}

pub fn enable_i_bit() {
    unsafe {
        asm!(
            "mrs {r}, sctlr_el1",
            "orr {r}, {r}, #(1 << 12)",
            "msr sctlr_el1, {r}",
            "isb",
            r = out(reg) _,
        );
    }
}

pub fn enable_mmu() {
    set_mair_tcr();
    flush_and_enable_m_bit();
    enable_c_bit();
    enable_i_bit();
}

pub fn flush_tlb_el0() {
    unsafe {
        asm!(
            "tlbi alle1",   // invalidate all stage-1 TLBs for lower EL
            "dsb ish",
            "isb",
        );
    }
}

/// Called from assembly: print exception info and halt.
#[unsafe(no_mangle)]
pub extern "C" fn handle_sync_exception(esr: u64, far: u64, elr: u64) -> ! {
    crate::println!("mmu: synchronous exception (EL1):");
    crate::println!("  ESR_EL1: 0x{:x}", esr);
    crate::println!("  FAR_EL1: 0x{:x}", far);
    crate::println!("  ELR_EL1: 0x{:x}", elr);
    let ec = (esr >> 26) & 0x3F;
    crate::println!("  EC: 0x{:x}", ec);
    crate::println!("mmu: halting");
    loop {
        core::hint::spin_loop();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn handle_el0_fault(esr: u64, far: u64, elr: u64) {
    let ec = (esr >> 26) & 0x3F;
    crate::println!("mmu: EL0 fault:");
    crate::println!("  ESR_EL1: 0x{:x}", esr);
    crate::println!("  FAR_EL1: 0x{:x}", far);
    crate::println!("  ELR_EL1: 0x{:x}", elr);
    match ec {
        0x24 | 0x25 => crate::println!("  type: data abort"),
        0x20 | 0x21 => crate::println!("  type: instruction abort"),
        _ => crate::println!("  EC: 0x{:x}", ec),
    }
}
