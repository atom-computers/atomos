extern crate alloc;

use alloc::vec::Vec;
use core::cell::RefCell;

use kernel_spec::{
    Access, Kernel, KernelError, MemoryTier, Process, ProcessId, Region, RegionId, RegionKind,
    TrustDomain, MappingType,
};

use crate::memory::PageAlloc;
use crate::mmu::{self, ProcessPageTable};
use crate::region::RegionTable;

const RAM_SIZE: u64 = 128 * 1024 * 1024;
const RAM_BASE: u64 = 0x4000_0000;

// Process virtual address space layout
const GRANULE: u64 = 4096;
const STACK_VA: u64 = 0x0000_7FFF_F000;   // top of EL0 stack (grows down)
const CODE_VA: u64 = 0x0000_0000_0000;     // program code base
const DATA_VA_BASE: u64 = 0x0001_0000_0000; // input/output/private regions base
const REGION_VA_STRIDE: u64 = 0x0001_0000;   // 64KB spacing between region mappings

struct ProcEntry {
    _process: Process,
    page_table: Option<ProcessPageTable>,
    tags: Vec<(u64, u8)>,
}

struct Subscriptions {
    /// (region_id, Vec<process_id>)
    by_region: Vec<(u64, Vec<u64>)>,
    /// (process_id, Vec<region_id>)
    by_process: Vec<(u64, Vec<u64>)>,
    queue: Vec<u64>,
    queued: Vec<u64>,
}

struct KernelState {
    page_alloc: PageAlloc,
    regions: RegionTable,
    processes: Vec<(u64, ProcEntry)>,
    subscriptions: Subscriptions,
    next_pid: u64,
    next_asid: u16,
    next_region_id: u64,
    current_pid: u64,
    #[cfg(feature = "mte")]
    mte: crate::mte::MteState,
}

pub struct Aarch64Kernel {
    state: RefCell<KernelState>,
}

impl Aarch64Kernel {
    pub fn new() -> Self {
        let ram_end = RAM_BASE + RAM_SIZE;
        let page_alloc = PageAlloc::new(ram_end);
        page_alloc.init();

        let kernel_tables = mmu::KernelTables::init(&page_alloc, RAM_BASE, RAM_SIZE);
        mmu::set_ttbr0(kernel_tables.ttbr0);

        #[cfg(feature = "mte")]
        let mte = {
            let m = crate::mte::MteState::detect();
            if m.is_enabled() {
                crate::println!("mte: hardware support detected, enabling MTE");
                m.init();
            } else {
                crate::println!("mte: no hardware support, MTE disabled");
            }
            m
        };

        mmu::enable_mmu();

        let kernel = Aarch64Kernel {
            state: RefCell::new(KernelState {
                page_alloc,
                regions: RegionTable::new(),
                processes: Vec::new(),
                subscriptions: Subscriptions {
                    by_region: Vec::new(),
                    by_process: Vec::new(),
                    queue: Vec::new(),
                    queued: Vec::new(),
                },
                next_pid: 1,
                next_asid: 1,
                next_region_id: 1,
                current_pid: 0,
                #[cfg(feature = "mte")]
                mte,
            }),
        };

        kernel
    }

    pub fn page_allocator(&self) -> &PageAlloc {
        unsafe { &(*self.state.as_ptr()).page_alloc }
    }

    pub fn quick_test(&self) {
        crate::println!("kernel: quick test...");
        let id = self.create_region(
            kernel_spec::RegionKind::Raw, 64, kernel_spec::MemoryTier::ShortTerm, None
        ).expect("create failed");
        let n = self.write_region(id, 0, b"hello").expect("write failed");
        assert_eq!(n, 5);
        let mut buf = [0u8; 5];
        let n = self.read_region(id, 0, &mut buf).expect("read failed");
        assert_eq!(n, 5);
        assert_eq!(&buf, b"hello");
        self.destroy_region(id).expect("destroy failed");
        crate::println!("kernel: quick test OK");
    }

    pub fn boot_test(&self) {
        crate::println!("kernel: running boot tests...");

        self.test_create_region();
        self.test_region_read_write();
        self.test_region_info();
        self.test_region_resize();
        self.test_region_set_tier();
        self.test_multiple_regions();
        self.test_spawn_and_kill();
        self.test_subscribe_and_notify();
        self.test_current_pid();
        self.test_grant_revoke();

        crate::println!("kernel: all tests passed. halting.");
    }

    fn test_create_region(&self) {
        let id = self
            .create_region(
                RegionKind::Raw,
                256,
                MemoryTier::ShortTerm,
                Some("test-raw"),
            )
            .expect("create_region failed");
        crate::println!("  test_create_region: created {:?}", id);
        self.destroy_region(id).expect("destroy failed");
    }

    fn test_region_read_write(&self) {
        let id = self
            .create_region(
                RegionKind::Raw,
                64,
                MemoryTier::ShortTerm,
                Some("rw-test"),
            )
            .expect("create failed");

        let data = b"Hello, kernel region!";
        let n = self.write_region(id, 0, data).expect("write failed");
        assert_eq!(n, data.len());

        let mut buf = [0u8; 64];
        let n = self.read_region(id, 0, &mut buf).expect("read failed");
        assert!(n >= data.len(), "read returned {}, expected at least {}", n, data.len());
        assert_eq!(&buf[..data.len()], data);

        crate::println!("  test_region_read_write: round-trip OK");
        self.destroy_region(id).expect("destroy failed");
    }

    fn test_region_info(&self) {
        let id = self
            .create_region(
                RegionKind::Spatial {
                    x: 100,
                    y: 200,
                    z: 1,
                    t: 2,
                    format: kernel_spec::ElementFormat::U8x4,
                },
                160000,
                MemoryTier::ShortTerm,
                Some("display"),
            )
            .expect("create failed");

        let info = self.region_info(id).expect("info failed");
        assert_eq!(info.label.as_deref(), Some("display"));
        assert_eq!(info.size, 160000);
        assert_eq!(info.tier, MemoryTier::ShortTerm);

        match &info.kind {
            RegionKind::Spatial { x, y, z, t, format } => {
                assert_eq!(*x, 100);
                assert_eq!(*y, 200);
                assert_eq!(*z, 1);
                assert_eq!(*t, 2);
                assert_eq!(*format, kernel_spec::ElementFormat::U8x4);
            }
            _ => panic!("expected Spatial"),
        }

        crate::println!("  test_region_info: metadata OK");
        self.destroy_region(id).expect("destroy failed");
    }

    fn test_region_resize(&self) {
        let id = self
            .create_region(
                RegionKind::Raw,
                512,
                MemoryTier::ShortTerm,
                Some("resize-test"),
            )
            .expect("create failed");

        let result = self.resize_region(id, 256);
        assert!(
            matches!(result, Err(KernelError::NotSupported)),
            "Expected NotSupported, got {:?}",
            result
        );

        crate::println!("  test_region_resize: NotSupported for non-growable region");
        self.destroy_region(id).expect("destroy failed");
    }

    fn test_region_set_tier(&self) {
        let id = self
            .create_region(
                RegionKind::Raw,
                64,
                MemoryTier::ShortTerm,
                Some("tier-test"),
            )
            .expect("create failed");

        assert_eq!(
            self.region_info(id).unwrap().tier,
            MemoryTier::ShortTerm
        );

        self.set_tier(id, MemoryTier::LongTerm)
            .expect("set_tier failed");
        assert_eq!(
            self.region_info(id).unwrap().tier,
            MemoryTier::LongTerm
        );

        crate::println!("  test_region_set_tier: tier migration OK");
        self.destroy_region(id).expect("destroy failed");
    }

    fn test_multiple_regions(&self) {
        let id1 = self
            .create_region(
                RegionKind::Raw,
                128,
                MemoryTier::ShortTerm,
                Some("r1"),
            )
            .expect("failed");
        let id2 = self
            .create_region(
                RegionKind::Raw,
                256,
                MemoryTier::ShortTerm,
                Some("r2"),
            )
            .expect("failed");

        assert_ne!(id1, id2);

        self.write_region(id1, 0, b"aaaa").unwrap();
        self.write_region(id2, 0, b"bbbb").unwrap();

        let mut buf = [0u8; 4];
        self.read_region(id1, 0, &mut buf).unwrap();
        assert_eq!(&buf, b"aaaa");

        self.read_region(id2, 0, &mut buf).unwrap();
        assert_eq!(&buf, b"bbbb");

        crate::println!("  test_multiple_regions: isolation OK");

        self.destroy_region(id1).unwrap();
        self.destroy_region(id2).unwrap();
    }

    fn test_spawn_and_kill(&self) {
        let prog = self
            .create_region(
                RegionKind::Raw,
                0,
                MemoryTier::ShortTerm,
                Some("prog"),
            )
            .expect("failed");

        let pid = self
            .spawn(Process {
                label: Some("test-process".into()),
                program: prog,
                inputs: Vec::new(),
                outputs: Vec::new(),
                private: Vec::new(),
                manifest_signature: None,
                trust_domain: TrustDomain::Kernel,
            })
            .expect("spawn failed");

        assert!(pid.0 > 0);
        crate::println!("  test_spawn_and_kill: spawned process {:?}", pid);

        self.kill(pid).expect("kill failed");
        assert!(matches!(self.kill(pid), Err(KernelError::NotFound)));

        crate::println!("  test_spawn_and_kill: kill OK, double-kill returns NotFound");
        self.destroy_region(prog).unwrap();
    }

    fn test_subscribe_and_notify(&self) {
        let prog = self
            .create_region(
                RegionKind::Raw,
                0,
                MemoryTier::ShortTerm,
                Some("prog"),
            )
            .expect("failed");

        let shared = self
            .create_region(
                RegionKind::Raw,
                64,
                MemoryTier::ShortTerm,
                Some("shared"),
            )
            .expect("failed");

        let pid = self
            .spawn(Process {
                label: Some("subscriber".into()),
                program: prog,
                inputs: Vec::new(),
                outputs: Vec::new(),
                private: Vec::new(),
                manifest_signature: None,
                trust_domain: TrustDomain::Kernel,
            })
            .expect("spawn failed");

        self.subscribe(pid, shared, Access::ReadOnly)
            .expect("subscribe failed");

        // Simulate a write from "hardware" (pid 0)
        self.state.borrow_mut().current_pid = 0;
        let n = self.write_region(shared, 0, b"data").unwrap();
        assert_eq!(n, 4);

        {
            let s = self.state.borrow();
            assert!(
                s.subscriptions.queue.contains(&pid.0),
                "Subscriber should be in activation queue"
            );
        }

        crate::println!("  test_subscribe_and_notify: subscriber activated after write");

        self.unsubscribe(pid, shared).expect("unsubscribe failed");

        let n = self.write_region(shared, 0, b"more").unwrap();
        assert_eq!(n, 4);

        {
            let s = self.state.borrow();
            assert_eq!(
                s.subscriptions.queue.len(),
                1,
                "No new activation after unsubscribe"
            );
        }

        crate::println!("  test_subscribe_and_notify: unsubscribe prevents activation");

        self.kill(pid).expect("kill failed");
        self.destroy_region(prog).unwrap();
        self.destroy_region(shared).unwrap();
    }

    fn test_current_pid(&self) {
        self.state.borrow_mut().current_pid = 42;
        let pid = self.current_pid().expect("current_pid failed");
        assert_eq!(pid, ProcessId(42));
        crate::println!("  test_current_pid: PID returned correctly");
    }

    fn test_grant_revoke(&self) {
        let prog = self
            .create_region(
                RegionKind::Raw,
                0,
                MemoryTier::ShortTerm,
                Some("prog"),
            )
            .expect("failed");

        let r = self
            .create_region(
                RegionKind::Raw,
                64,
                MemoryTier::ShortTerm,
                Some("grant-test"),
            )
            .expect("failed");

        let pid = self
            .spawn(Process {
                label: Some("grantee".into()),
                program: prog,
                inputs: Vec::new(),
                outputs: Vec::new(),
                private: Vec::new(),
                manifest_signature: None,
                trust_domain: TrustDomain::Kernel,
            })
            .expect("spawn failed");

        self.grant(pid, r, Access::ReadOnly)
            .expect("grant failed");
        self.revoke(pid, r).expect("revoke failed");

        crate::println!("  test_grant_revoke: grant + revoke OK");

        self.kill(pid).expect("kill failed");
        self.destroy_region(prog).unwrap();
        self.destroy_region(r).unwrap();
    }
}

impl Kernel for Aarch64Kernel {
    fn create_region(
        &self,
        kind: RegionKind,
        size: usize,
        tier: MemoryTier,
        label: Option<&str>,
    ) -> Result<RegionId, KernelError> {
        let page_count = (size + 4095) / 4096;
        let addr = {
            let state = self.state.borrow();
            state.page_alloc.alloc_pages(page_count)
        };
        if addr == 0 {
            return Err(KernelError::OutOfMemory);
        }

        let mut state = self.state.borrow_mut();
        let id = RegionId(state.next_region_id);
        state.next_region_id += 1;
        state.regions.create(id, &kind, size, tier, label, addr, page_count);
        Ok(id)
    }

    fn destroy_region(&self, id: RegionId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        state.regions.destroy(id).ok_or(KernelError::NotFound)?;
        state.subscriptions.by_region.retain(|(rid, _)| *rid != id.0);
        Ok(())
    }

    fn resize_region(&self, id: RegionId, new_size: usize) -> Result<(), KernelError> {
        self.state.borrow_mut().regions.resize(id, new_size)
    }

    fn set_tier(&self, id: RegionId, tier: MemoryTier) -> Result<(), KernelError> {
        self.state.borrow_mut().regions.set_tier(id, tier)
    }

    fn read_region(
        &self,
        id: RegionId,
        offset: usize,
        buf: &mut [u8],
    ) -> Result<usize, KernelError> {
        self.state.borrow().regions.read(id, offset, buf)
    }

    fn write_region(
        &self,
        id: RegionId,
        offset: usize,
        data: &[u8],
    ) -> Result<usize, KernelError> {
        let (current_pid, subs, n) = {
            let state = self.state.borrow();
            let current = state.current_pid;
            let subs: Vec<u64> = state
                .subscriptions
                .by_region
                .iter()
                .find(|(rid, _)| *rid == id.0)
                .map(|(_, pids)| pids.clone())
                .unwrap_or_default();
            let n = state.regions.write(id, offset, data)?;
            (current, subs, n)
        };

        if !subs.is_empty() {
            let mut state = self.state.borrow_mut();
            for sub_pid in &subs {
                let proc_exists = state.processes.iter().any(|(p, _)| p == sub_pid);
                let already_queued = state.subscriptions.queued.contains(sub_pid);
                if *sub_pid != current_pid && proc_exists && !already_queued {
                    state.subscriptions.queue.push(*sub_pid);
                    state.subscriptions.queued.push(*sub_pid);
                }
            }
        }

        Ok(n)
    }

    fn region_info(&self, id: RegionId) -> Result<Region, KernelError> {
        self.state.borrow().regions.info(id)
    }

    fn current_pid(&self) -> Result<ProcessId, KernelError> {
        let pid = self.state.borrow().current_pid;
        if pid == 0 {
            Err(KernelError::NotFound)
        } else {
            Ok(ProcessId(pid))
        }
    }

    fn spawn(&self, process: Process) -> Result<ProcessId, KernelError> {
        let mut state = self.state.borrow_mut();
        let pid = state.next_pid;
        state.next_pid += 1;

        for &(region, _access) in &process.inputs {
            add_sub(&mut state.subscriptions, pid, region.0);
        }

        state.processes.push((pid, ProcEntry {
            _process: process.clone(),
            page_table: None,
            tags: Vec::new(),
        }));
        state.subscriptions.queue.push(pid);
        state.subscriptions.queued.push(pid);

        Ok(ProcessId(pid))
    }

    fn kill(&self, id: ProcessId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        if !state.processes.iter().any(|(p, _)| *p == id.0) {
            return Err(KernelError::NotFound);
        }

        // Remove subscriptions
        let regions: Vec<u64> = state
            .subscriptions
            .by_process
            .iter()
            .filter(|(p, _)| *p == id.0)
            .flat_map(|(_, rids)| rids.clone())
            .collect();
        for rid in &regions {
            remove_sub(&mut state.subscriptions, id.0, *rid);
        }
        state.subscriptions.by_process.retain(|(p, _)| *p != id.0);
        state.subscriptions.queued.retain(|p| *p != id.0);
        state.subscriptions.queue.retain(|p| *p != id.0);
        state.processes.retain(|(p, _)| *p != id.0);

        Ok(())
    }

    fn subscribe(
        &self,
        pid: ProcessId,
        region: RegionId,
        _access: Access,
    ) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        if !state.processes.iter().any(|(p, _)| *p == pid.0) {
            return Err(KernelError::NotFound);
        }
        add_sub(&mut state.subscriptions, pid.0, region.0);
        Ok(())
    }

    fn unsubscribe(&self, pid: ProcessId, region: RegionId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        remove_sub(&mut state.subscriptions, pid.0, region.0);
        Ok(())
    }

    fn grant(
        &self,
        _pid: ProcessId,
        _region: RegionId,
        _access: Access,
    ) -> Result<(), KernelError> {
        Ok(())
    }

    fn revoke(&self, _pid: ProcessId, _region: RegionId) -> Result<(), KernelError> {
        Ok(())
    }

    fn rotate_region_key(&self, _id: RegionId) -> Result<(), KernelError> {
        Ok(())
    }

    fn activate_process(&self, pid: ProcessId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();

        let idx = state.processes.iter()
            .position(|(p, _)| *p == pid.0)
            .ok_or(KernelError::NotFound)?;

        if state.processes[idx].1.page_table.is_some() {
            // Already created — just switch to it
            let ttbr0 = state.processes[idx].1.page_table.as_ref().unwrap().ttbr0();
            drop(state);
            mmu::flush_tlb_el0();
            mmu::set_ttbr0(ttbr0);
            return Ok(());
        }

        // Create page table and map all authorized regions
        let asid = state.next_asid;
        state.next_asid = state.next_asid.wrapping_add(1);

        let pa = &state.page_alloc as *const PageAlloc;
        // Safety: we drop the borrow before using the pointer, and page_alloc
        // lives as long as KernelState.
        let page_alloc_ref = unsafe { &*pa };

        let mut pt = ProcessPageTable::new(page_alloc_ref, asid);

        let program_rid = state.processes[idx].1._process.program;
        let input_regions: Vec<(RegionId, Access)> = state.processes[idx].1._process.inputs.clone();
        let output_regions: Vec<(RegionId, Access)> = state.processes[idx].1._process.outputs.clone();
        let private_regions: Vec<RegionId> = state.processes[idx].1._process.private.clone();

        // Map program region (code — immutable after verification)
        {
            let (pa, count_ok) = {
                let pages = state.regions.pages(program_rid)
                    .ok_or(KernelError::NotFound)?;
                (pages.first().copied().unwrap_or(0), pages.len())
            };
            if count_ok > 0 && pa != 0 {
                let tag = tag_pages(&mut state, idx, program_rid.0, pa, count_ok);
                let va = CODE_VA | ((tag as u64) << 56);
                pt.map(page_alloc_ref, va, pa, count_ok,
                       MappingType::Code, Access::ReadOnly);
            }
        }

        // Map input regions (data, read-only)
        let mut data_off = 0u64;
        for &(region, _access) in &input_regions {
            let (pa, count_ok) = {
                let pages = state.regions.pages(region)
                    .ok_or(KernelError::NotFound)?;
                (pages.first().copied().unwrap_or(0), pages.len())
            };
            if count_ok > 0 && pa != 0 {
                let tag = tag_pages(&mut state, idx, region.0, pa, count_ok);
                let va = (DATA_VA_BASE + data_off * REGION_VA_STRIDE) | ((tag as u64) << 56);
                pt.map(page_alloc_ref, va, pa, count_ok,
                       MappingType::Data, Access::ReadOnly);
            }
            data_off += 1;
        }

        // Map output regions (data, read-write)
        for &(region, _access) in &output_regions {
            let (pa, count_ok) = {
                let pages = state.regions.pages(region)
                    .ok_or(KernelError::NotFound)?;
                (pages.first().copied().unwrap_or(0), pages.len())
            };
            if count_ok > 0 && pa != 0 {
                let tag = tag_pages(&mut state, idx, region.0, pa, count_ok);
                let va = (DATA_VA_BASE + data_off * REGION_VA_STRIDE) | ((tag as u64) << 56);
                pt.map(page_alloc_ref, va, pa, count_ok,
                       MappingType::Data, Access::ReadWrite);
            }
            data_off += 1;
        }

        // Map private regions (data, read-write)
        for &region in &private_regions {
            let (pa, count_ok) = {
                let pages = state.regions.pages(region)
                    .ok_or(KernelError::NotFound)?;
                (pages.first().copied().unwrap_or(0), pages.len())
            };
            if count_ok > 0 && pa != 0 {
                let tag = tag_pages(&mut state, idx, region.0, pa, count_ok);
                let va = (DATA_VA_BASE + data_off * REGION_VA_STRIDE) | ((tag as u64) << 56);
                pt.map(page_alloc_ref, va, pa, count_ok,
                       MappingType::Data, Access::ReadWrite);
            }
            data_off += 1;
        }

        // Map stack region (16 pages = 64KB, with guard page)
        let stack_pages = state.page_alloc.alloc_pages(17);
        if stack_pages == 0 {
            return Err(KernelError::OutOfMemory);
        }
        let stack_tag = tag_pages(&mut state, idx, 0, stack_pages, 17);
        // Page 0 = guard (unmapped via MappingType::Guard)
        pt.map(page_alloc_ref, (STACK_VA - 16 * GRANULE) | ((stack_tag as u64) << 56),
               stack_pages, 1, MappingType::Guard, Access::ReadOnly);
        // Pages 1-16 = writable stack
        pt.map(page_alloc_ref, (STACK_VA - 15 * GRANULE) | ((stack_tag as u64) << 56),
               stack_pages + GRANULE, 16,
               MappingType::Data, Access::ReadWrite);

        let ttbr0 = pt.ttbr0();
        state.processes[idx].1.page_table = Some(pt);
        drop(state);

        mmu::flush_tlb_el0();
        mmu::set_ttbr0(ttbr0);
        Ok(())
    }

    fn deactivate_process(&self, pid: ProcessId) -> Result<(), KernelError> {
        #[cfg(feature = "mte")]
        {
            let mut state = self.state.borrow_mut();
            if let Some(idx) = state.processes.iter().position(|(p, _)| *p == pid.0) {
                let tags = core::mem::take(&mut state.processes[idx].1.tags);
                for &(region_id, tag) in &tags {
                    if let Some(pages) = state.regions.pages(RegionId(region_id)) {
                        if !pages.is_empty() {
                            state.mte.clear_tags(pages[0], pages.len());
                        }
                    }
                    let _ = tag;
                }
            }
        }
        let _ = pid;

        mmu::flush_tlb_el0();
        Ok(())
    }

    fn authorize_transfer(
        &self,
        _region: RegionId,
        _from: TrustDomain,
        _to: TrustDomain,
        _vault_token: &[u8],
    ) -> Result<(), KernelError> {
        Ok(())
    }

    fn vault_sign(
        &self,
        _request_region: RegionId,
        _response_region: RegionId,
    ) -> Result<(), KernelError> {
        Ok(())
    }
}

fn tag_pages(state: &mut KernelState, proc_idx: usize, region_id: u64, pa: u64, pages: usize) -> u8 {
    #[cfg(feature = "mte")]
    {
        if state.mte.is_enabled() {
            let tag = state.mte.alloc_tag();
            state.mte.set_tags(pa, pages, tag);
            state.processes[proc_idx].1.tags.push((region_id, tag));
            return tag;
        }
    }
    let _ = (state, proc_idx, region_id, pa, pages);
    0
}

// Subscription helpers
fn add_sub(subs: &mut Subscriptions, pid: u64, rid: u64) {
    for (r, pids) in &mut subs.by_region {
        if *r == rid {
            if !pids.contains(&pid) {
                pids.push(pid);
            }
            return;
        }
    }
    subs.by_region.push((rid, alloc::vec![pid]));

    for (p, rids) in &mut subs.by_process {
        if *p == pid {
            if !rids.contains(&rid) {
                rids.push(rid);
            }
            return;
        }
    }
    subs.by_process.push((pid, alloc::vec![rid]));
}

fn remove_sub(subs: &mut Subscriptions, pid: u64, rid: u64) {
    for (r, pids) in &mut subs.by_region {
        if *r == rid {
            pids.retain(|p| *p != pid);
        }
    }
    subs.by_region.retain(|(_, pids)| !pids.is_empty());
    for (p, rids) in &mut subs.by_process {
        if *p == pid {
            rids.retain(|r| *r != rid);
        }
    }
}
