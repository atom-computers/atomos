use kernel_spec::{Access, Kernel, MemoryTier, Process, RegionKind};

use crate::MockKernel;

/// A reactive dataflow demo: two processes communicate via shared regions.
///
/// # Setup
///
/// - **Region `shared`**: a buffer where process A writes incrementing counter
///   values and process B reads them.
/// - **Region `tick`**: a signal that process B writes after reading, to wake
///   process A for its next write.
///
/// # Flow
///
///     A writes counter → B wakes, reads counter, writes tick →
///     A wakes, increments counter, writes to shared → ...
///
/// After 5 rounds, process A kills itself and the system goes idle.
#[test]
fn reactive_dataflow_demo() {
    let kernel = MockKernel::new();
    let program = kernel
        .create_region(RegionKind::Raw, 0, MemoryTier::ShortTerm)
        .unwrap();

    let shared = kernel
        .create_region(RegionKind::Raw, 16, MemoryTier::ShortTerm)
        .unwrap();
    let tick = kernel
        .create_region(RegionKind::Raw, 1, MemoryTier::ShortTerm)
        .unwrap();

    let max_count = std::rc::Rc::new(std::cell::RefCell::new(0u32));
    let max_count_out = max_count.clone();

    let process_a = Process {
        program,
        inputs: vec![(tick, Access::ReadOnly)],
        outputs: vec![(shared, Access::ReadWrite)],
        private: vec![],
    };

    let process_b = Process {
        program,
        inputs: vec![(shared, Access::ReadOnly)],
        outputs: vec![(tick, Access::ReadWrite)],
        private: vec![],
    };

    // Process B: observer — wakes when shared changes, reads it, pulses tick
    let _ = kernel.spawn_with_closure(process_b, Box::new({
        move |k: &MockKernel| {
            let mut buf = [0u8; 4];
            let n = k.read_region(shared, 0, &mut buf).unwrap();
            if n >= 4 {
                let val = u32::from_le_bytes(buf);
                println!("[B] observed: {}", val);
            }
            let _ = k.write_region(tick, 0, &[1u8]).unwrap();
        }
    }));

    // Process A: producer — wakes on tick, increments counter, writes to shared
    let _ = kernel.spawn_with_closure(process_a, Box::new({
        let mut counter: u32 = 0;
        move |k: &MockKernel| {
            counter += 1;
            let bytes = counter.to_le_bytes();
            k.write_region(shared, 0, &bytes).unwrap();
            println!("[A] wrote: {}", counter);

            if counter >= 5 {
                println!("[A] done, exiting");
                *max_count.borrow_mut() = counter;
                let _ = k.kill(k.current_pid().unwrap());
            }
        }
    }));

    kernel.run_until_idle();

    assert_eq!(*max_count_out.borrow(), 5);
}
