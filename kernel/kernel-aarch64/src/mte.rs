use core::arch::asm;

const TAG_SHIFT: u64 = 56;
const TAG_GRANULE: usize = 16;

const TCR_TBI0: u64 = 1 << 37;
const TCR_TBI1: u64 = 1 << 38;
const TCR_TCMA0: u64 = 1 << 57;
const TCR_TCMA1: u64 = 1 << 58;

const SCTLR_ATA: u64 = 1 << 43;
const SCTLR_ATA0: u64 = 1 << 42;

pub struct MteState {
    enabled: bool,
    next_tag: u8,
}

impl MteState {
    pub fn detect() -> Self {
        let enabled = {
            let mmfr2: u64;
            unsafe {
                asm!("mrs {0}, id_aa64mmfr2_el1", out(reg) mmfr2);
            }
            let mte_field = (mmfr2 >> 32) & 0xF;
            mte_field >= 1
        };

        MteState {
            enabled,
            next_tag: 1,
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn init(&self) {
        if !self.enabled {
            return;
        }
        unsafe {
            let mut tcr: u64;
            asm!("mrs {0}, tcr_el1", out(reg) tcr);
            tcr |= TCR_TBI0 | TCR_TBI1 | TCR_TCMA0 | TCR_TCMA1;
            asm!("msr tcr_el1, {0}", in(reg) tcr);

            let gcs: u64 = 1; // bit 0 = expose tag generation instructions to EL0
            asm!("msr gcscr_el1, {0}", in(reg) gcs);

            let mut sctlr: u64;
            asm!("mrs {0}, sctlr_el1", out(reg) sctlr);
            sctlr |= SCTLR_ATA | SCTLR_ATA0;
            asm!("msr sctlr_el1, {0}", in(reg) sctlr);

            asm!("isb");
        }
    }

    pub fn alloc_tag(&mut self) -> u8 {
        if !self.enabled {
            return 0;
        }
        let tag = self.next_tag;
        self.next_tag = self.next_tag.wrapping_add(1);
        if self.next_tag == 0 {
            self.next_tag = 1;
        }
        tag
    }

    /// Tag physical pages with the given 4-bit tag.
    /// Uses STG instruction: stores tag from source register bits [59:56]
    /// into the tag memory for each 16-byte granule.
    pub fn set_tags(&self, pa: u64, pages: usize, tag: u8) {
        if !self.enabled {
            return;
        }
        let num_granules = pages * 4096 / TAG_GRANULE;
        let tag_val = (tag as u64) << TAG_SHIFT;
        for i in 0..num_granules {
            let addr = pa + i as u64 * TAG_GRANULE as u64;
            unsafe {
                asm!("stg {tag}, [{addr}]", tag = in(reg) tag_val, addr = in(reg) addr);
            }
        }
    }

    pub fn clear_tags(&self, pa: u64, pages: usize) {
        if !self.enabled {
            return;
        }
        let num_granules = pages * 4096 / TAG_GRANULE;
        for i in 0..num_granules {
            let addr = pa + i as u64 * TAG_GRANULE as u64;
            unsafe {
                asm!("stg xzr, [{addr}]", addr = in(reg) addr);
            }
        }
    }
}
