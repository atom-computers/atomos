extern crate alloc;

use alloc::vec::Vec;
use core::ptr::{copy_nonoverlapping, write_bytes};

use kernel_spec::{MemoryTier, Region, RegionFlags, RegionId, RegionKind};

const PAGE_SIZE: usize = 4096;

struct RegionEntry {
    label: Option<alloc::string::String>,
    kind: RegionKind,
    size: usize,
    tier: MemoryTier,
    flags: RegionFlags,
    pages: Vec<u64>,
}

pub struct RegionTable {
    regions: Vec<(u64, RegionEntry)>,
}

impl RegionTable {
    pub const fn new() -> Self {
        RegionTable { regions: Vec::new() }
    }

    pub fn create(
        &mut self,
        id: RegionId,
        kind: &RegionKind,
        size: usize,
        tier: MemoryTier,
        label: Option<&str>,
        first_page_addr: u64,
        page_count: usize,
    ) {
        let mut pages = Vec::with_capacity(page_count);
        for i in 0..page_count {
            pages.push(first_page_addr + i as u64 * PAGE_SIZE as u64);
        }

        let total_bytes = page_count * PAGE_SIZE;
        unsafe {
            write_bytes(first_page_addr as *mut u8, 0, total_bytes);
        }

        let stored_label = label.map(|s| alloc::string::String::from(s));
        self.regions.push((
            id.0,
            RegionEntry {
                label: stored_label,
                kind: kind.clone(),
                size,
                tier,
                flags: RegionFlags::READ | RegionFlags::WRITE,
                pages,
            },
        ));
    }

    fn find(&self, id: u64) -> Option<usize> {
        self.regions.iter().position(|(k, _)| *k == id)
    }

    fn find_mut(&mut self, id: u64) -> Option<&mut RegionEntry> {
        self.regions.iter_mut().find(|(k, _)| *k == id).map(|(_, v)| v)
    }

    pub fn destroy(&mut self, id: RegionId) -> Option<()> {
        let idx = self.find(id.0)?;
        self.regions.remove(idx);
        Some(())
    }

    pub fn resize(&mut self, id: RegionId, new_size: usize) -> Result<(), kernel_spec::KernelError> {
        let entry = self.find_mut(id.0).ok_or(kernel_spec::KernelError::NotFound)?;
        if !entry.flags.contains(RegionFlags::GROWABLE) {
            return Err(kernel_spec::KernelError::NotSupported);
        }
        let page_count = (new_size + PAGE_SIZE - 1) / PAGE_SIZE;
        if page_count > entry.pages.len() {
            return Err(kernel_spec::KernelError::OutOfMemory);
        }
        entry.size = new_size;
        Ok(())
    }

    pub fn read(
        &self,
        id: RegionId,
        offset: usize,
        buf: &mut [u8],
    ) -> Result<usize, kernel_spec::KernelError> {
        let idx = self.find(id.0).ok_or(kernel_spec::KernelError::NotFound)?;
        let entry = &self.regions[idx].1;

        if offset >= entry.size {
            return Ok(0);
        }

        let max_read = core::cmp::min(buf.len(), entry.size - offset);
        let mut remaining = max_read;
        let mut buf_offset = 0;
        let mut region_offset = offset;

        while remaining > 0 {
            let page_idx = region_offset / PAGE_SIZE;
            let page_off = region_offset % PAGE_SIZE;
            let chunk = core::cmp::min(remaining, PAGE_SIZE - page_off);
            let pa = entry.pages[page_idx];
            unsafe {
                copy_nonoverlapping(
                    (pa as usize + page_off) as *const u8,
                    buf[buf_offset..].as_mut_ptr(),
                    chunk,
                );
            }
            remaining -= chunk;
            buf_offset += chunk;
            region_offset += chunk;
        }

        Ok(max_read)
    }

    pub fn write(
        &self,
        id: RegionId,
        offset: usize,
        data: &[u8],
    ) -> Result<usize, kernel_spec::KernelError> {
        let idx = self.find(id.0).ok_or(kernel_spec::KernelError::NotFound)?;
        let entry = &self.regions[idx].1;

        if offset >= entry.size {
            return Ok(0);
        }

        let max_write = core::cmp::min(data.len(), entry.size - offset);
        let mut remaining = max_write;
        let mut data_offset = 0;
        let mut region_offset = offset;

        while remaining > 0 {
            let page_idx = region_offset / PAGE_SIZE;
            let page_off = region_offset % PAGE_SIZE;
            let chunk = core::cmp::min(remaining, PAGE_SIZE - page_off);
            let pa = entry.pages[page_idx];
            unsafe {
                copy_nonoverlapping(
                    data[data_offset..].as_ptr(),
                    (pa as usize + page_off) as *mut u8,
                    chunk,
                );
            }
            remaining -= chunk;
            data_offset += chunk;
            region_offset += chunk;
        }

        Ok(max_write)
    }

    pub fn info(&self, id: RegionId) -> Result<Region, kernel_spec::KernelError> {
        let idx = self.find(id.0).ok_or(kernel_spec::KernelError::NotFound)?;
        let entry = &self.regions[idx].1;

        Ok(Region {
            id,
            label: entry.label.clone(),
            kind: entry.kind.clone(),
            size: entry.size,
            tier: entry.tier,
            flags: entry.flags,
        })
    }

    pub fn set_tier(&mut self, id: RegionId, tier: MemoryTier) -> Result<(), kernel_spec::KernelError> {
        let entry = self.find_mut(id.0).ok_or(kernel_spec::KernelError::NotFound)?;
        entry.tier = tier;
        Ok(())
    }
}
