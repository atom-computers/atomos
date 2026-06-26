use core::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{Read, Write};

use kernel_spec::{
    Access, Kernel, KernelError, MemoryTier, Process, ProcessId, Region, RegionFlags, RegionId,
    RegionKind, TrustDomain,
};

type ProcessClosure = Box<dyn FnMut(&MockKernel)>;

struct MockRegion {
    label: Option<String>,
    kind: RegionKind,
    data: Vec<u8>,
    tier: MemoryTier,
    flags: RegionFlags,
    long_term_path: Option<std::path::PathBuf>,
}

struct MockProcess {
    process: Process,
    closure: Option<ProcessClosure>,
}

struct MockState {
    regions: HashMap<RegionId, MockRegion>,
    processes: HashMap<ProcessId, MockProcess>,
    subscriptions: HashMap<RegionId, HashSet<ProcessId>>,
    activation_queue: VecDeque<ProcessId>,
    queued: HashSet<ProcessId>,
    dead: HashSet<ProcessId>,
    next_region_id: u64,
    next_process_id: u64,
    current_pid: Option<ProcessId>,
}

pub struct MockKernel {
    state: RefCell<MockState>,
}

impl MockKernel {
    pub fn new() -> Self {
        MockKernel {
            state: RefCell::new(MockState {
                regions: HashMap::new(),
                processes: HashMap::new(),
                subscriptions: HashMap::new(),
                activation_queue: VecDeque::new(),
                queued: HashSet::new(),
                dead: HashSet::new(),
                next_region_id: 1,
                next_process_id: 1,
                current_pid: None,
            }),
        }
    }

    /// Spawn a process with an inline closure as its program.
    ///
    /// In a real kernel, the program is loaded from a region. Here we accept
    /// a Rust closure directly so the spec can be tested on the host without
    /// any code loading infrastructure.
    pub fn spawn_with_closure(
        &self,
        process: Process,
        closure: ProcessClosure,
    ) -> Result<ProcessId, KernelError> {
        let pid = self.spawn_impl(process, Some(closure))?;
        Ok(pid)
    }

    fn spawn_impl(
        &self,
        process: Process,
        closure: Option<ProcessClosure>,
    ) -> Result<ProcessId, KernelError> {
        let mut state = self.state.borrow_mut();
        let pid = ProcessId(state.next_process_id);
        state.next_process_id += 1;

        state.processes.insert(
            pid,
            MockProcess {
                process: process.clone(),
                closure,
            },
        );

        for &(region, _access) in &process.inputs {
            state
                .subscriptions
                .entry(region)
                .or_default()
                .insert(pid);
        }

        state.activation_queue.push_back(pid);
        state.queued.insert(pid);

        Ok(pid)
    }

    /// Execute one activation from the queue.
    ///
    /// Returns `true` if a process was activated, `false` if the queue was
    /// empty (the system is idle).
    pub fn step(&self) -> bool {
        let pid = {
            let mut state = self.state.borrow_mut();
            let pid = state.activation_queue.pop_front();
            if let Some(p) = pid {
                state.queued.remove(&p);
            }
            pid
        };

        let Some(pid) = pid else {
            return false;
        };

        if self.state.borrow().dead.contains(&pid) {
            return self.step();
        }

        let mut closure_opt = {
            let mut state = self.state.borrow_mut();
            state.processes.get_mut(&pid).unwrap().closure.take()
        };
        self.state.borrow_mut().current_pid = Some(pid);

        {
            let state = self.state.borrow();
            if let Some(proc) = state.processes.get(&pid) {
                if let Some(ref label) = proc.process.label {
                    println!("[kernel] activate {}", label);
                }
            }
        }

        if let Some(ref mut f) = closure_opt {
            f(self);
        }

        let is_dead = self.state.borrow().dead.contains(&pid);
        let mut state = self.state.borrow_mut();
        state.current_pid = None;

        if !is_dead {
            if let Some(process) = state.processes.get_mut(&pid) {
                process.closure = closure_opt;
            }
        }

        true
    }

    /// Run step repeatedly until the activation queue is empty.
    pub fn run_until_idle(&self) {
        while self.step() {}
    }
}

impl Kernel for MockKernel {
    fn create_region(
        &self,
        kind: RegionKind,
        size: usize,
        tier: MemoryTier,
        label: Option<&str>,
    ) -> Result<RegionId, KernelError> {
        let mut state = self.state.borrow_mut();
        let id = RegionId(state.next_region_id);
        state.next_region_id += 1;

        let long_term_path = if tier == MemoryTier::LongTerm {
            let dir = std::env::temp_dir().join("kernel-mock");
            std::fs::create_dir_all(&dir).map_err(|_| KernelError::OutOfMemory)?;
            let path = dir.join(format!("region_{}.bin", id.0));
            Some(path)
        } else {
            None
        };

        state.regions.insert(
            id,
            MockRegion {
                label: label.map(|s| s.to_string()),
                kind,
                data: vec![0u8; size],
                tier,
                flags: RegionFlags::READ | RegionFlags::WRITE,
                long_term_path,
            },
        );

        Ok(id)
    }

    fn destroy_region(&self, id: RegionId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        let region = state.regions.remove(&id).ok_or(KernelError::NotFound)?;
        if let Some(path) = &region.long_term_path {
            let _ = std::fs::remove_file(path);
        }
        state.subscriptions.remove(&id);
        Ok(())
    }

    fn resize_region(&self, id: RegionId, new_size: usize) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        let region = state.regions.get_mut(&id).ok_or(KernelError::NotFound)?;
        if !region.flags.contains(RegionFlags::GROWABLE) {
            return Err(KernelError::NotSupported);
        }
        region.data.resize(new_size, 0u8);
        Ok(())
    }

    fn set_tier(&self, id: RegionId, tier: MemoryTier) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        let region = state.regions.get_mut(&id).ok_or(KernelError::NotFound)?;
        if region.tier == tier {
            return Ok(());
        }

        match (region.tier, tier) {
            (MemoryTier::LongTerm, MemoryTier::ShortTerm) => {
                if let Some(path) = &region.long_term_path {
                    if let Ok(mut f) = std::fs::File::open(path) {
                        let _ = f.read_exact(&mut region.data);
                    }
                    let _ = std::fs::remove_file(path);
                }
                region.long_term_path = None;
            }
            (MemoryTier::ShortTerm, MemoryTier::LongTerm) => {
                let dir = std::env::temp_dir().join("kernel-mock");
                std::fs::create_dir_all(&dir).map_err(|_| KernelError::OutOfMemory)?;
                let path = dir.join(format!("region_{}.bin", id.0));
                if let Ok(mut f) = std::fs::File::create(&path) {
                    let _ = f.write_all(&region.data);
                }
                region.long_term_path = Some(path);
            }
            (_, _) => {}
        }

        region.tier = tier;
        Ok(())
    }

    fn read_region(
        &self,
        id: RegionId,
        offset: usize,
        buf: &mut [u8],
    ) -> Result<usize, KernelError> {
        let state = self.state.borrow();
        let region = state.regions.get(&id).ok_or(KernelError::NotFound)?;
        let end = core::cmp::min(offset + buf.len(), region.data.len());
        if offset >= region.data.len() {
            return Ok(0);
        }
        let len = end - offset;
        buf[..len].copy_from_slice(&region.data[offset..end]);
        Ok(len)
    }

    fn write_region(
        &self,
        id: RegionId,
        offset: usize,
        data: &[u8],
    ) -> Result<usize, KernelError> {
        let current_pid;
        let subscribers;
        {
            let mut state = self.state.borrow_mut();
            let region = state.regions.get_mut(&id).ok_or(KernelError::NotFound)?;
            let end = core::cmp::min(offset + data.len(), region.data.len());
            if offset >= region.data.len() {
                return Ok(0);
            }
            let len = end - offset;
            region.data[offset..end].copy_from_slice(&data[..len]);

            current_pid = state.current_pid;
            subscribers = state
                .subscriptions
                .get(&id)
                .cloned()
                .unwrap_or_default();
        }

        for sub_pid in &subscribers {
            if Some(*sub_pid) != current_pid {
                let mut state = self.state.borrow_mut();
                if state.processes.contains_key(sub_pid)
                    && !state.dead.contains(sub_pid)
                    && !state.queued.contains(sub_pid)
                {
                    state.activation_queue.push_back(*sub_pid);
                    state.queued.insert(*sub_pid);
                }
            }
        }

        Ok(core::cmp::min(data.len(), {
            let state = self.state.borrow();
            let region = state.regions.get(&id).unwrap();
            region.data.len().saturating_sub(offset)
        }))
    }

    fn region_info(&self, id: RegionId) -> Result<Region, KernelError> {
        let state = self.state.borrow();
        let r = state.regions.get(&id).ok_or(KernelError::NotFound)?;
        Ok(Region {
            id,
            label: r.label.clone(),
            kind: r.kind.clone(),
            size: r.data.len(),
            tier: r.tier,
            flags: r.flags,
        })
    }

    fn current_pid(&self) -> Result<ProcessId, KernelError> {
        self.state
            .borrow()
            .current_pid
            .ok_or(KernelError::NotFound)
    }

    fn spawn(&self, process: Process) -> Result<ProcessId, KernelError> {
        self.spawn_impl(process, None)
    }

    fn kill(&self, id: ProcessId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        if !state.processes.contains_key(&id) {
            return Err(KernelError::NotFound);
        }
        state.dead.insert(id);

        for subs in state.subscriptions.values_mut() {
            subs.remove(&id);
        }
        state
            .subscriptions
            .retain(|_, subs| !subs.is_empty());

        let output_regions: Vec<RegionId> = state
            .processes
            .get(&id)
            .unwrap()
            .process
            .outputs
            .iter()
            .map(|(r, _)| *r)
            .collect();
        for region in output_regions {
            state
                .subscriptions
                .entry(region)
                .or_default()
                .remove(&id);
        }

        Ok(())
    }

    fn subscribe(
        &self,
        pid: ProcessId,
        region: RegionId,
        _access: Access,
    ) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        if !state.processes.contains_key(&pid) {
            return Err(KernelError::NotFound);
        }
        state.subscriptions.entry(region).or_default().insert(pid);
        Ok(())
    }

    fn unsubscribe(&self, pid: ProcessId, region: RegionId) -> Result<(), KernelError> {
        let mut state = self.state.borrow_mut();
        if let Some(subs) = state.subscriptions.get_mut(&region) {
            subs.remove(&pid);
        }
        state
            .subscriptions
            .retain(|_, subs| !subs.is_empty());
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

    fn activate_process(&self, _pid: ProcessId) -> Result<(), KernelError> {
        Ok(())
    }

    fn deactivate_process(&self, _pid: ProcessId) -> Result<(), KernelError> {
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
