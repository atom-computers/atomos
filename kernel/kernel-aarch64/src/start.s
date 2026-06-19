.section ".text._start", "ax"
.globl _start

_start:
    // QEMU starts at 0x40080000 with MMU off, in EL1.
    // x0 contains the FDT pointer.

    // Save FDT pointer for later
    mov     x19, x0

    // Disable data cache and instruction cache (QEMU enables them by default).
    // SCTLR_EL1 bits: C=2, I=12 — clear both.
    mrs     x20, sctlr_el1
    bic     x20, x20, #(1 << 2)   // clear C (data cache)
    bic     x20, x20, #(1 << 12)  // clear I (instruction cache)
    msr     sctlr_el1, x20
    isb

    // Early sanity: write 0x21 ('!') to UART TX to confirm we run
    mov     x20, #0x09000000
    mov     w21, #0x21
    str     w21, [x20]

    // Zero .bss
    adr     x1, __bss_start
    adr     x2, __bss_end
1:  cmp     x1, x2
    b.eq    2f
    stp     xzr, xzr, [x1], #16
    b       1b

    // Set up boot stack
2:  adr     x0, __boot_stack_top
    mov     sp, x0

    // Mask IRQs and FIQs at the CPU level so virtio devices don't crash us
    msr     daifset, #0b0110    // set I and F bits

    // Early Rust trace
    mov     w21, #0x52          // 'R' for Rust
    str     w21, [x20]

    // Jump to Rust entry
    mov     x0, x19             // pass FDT pointer
    bl      kernel_main

    // If kernel_main returns, halt
    mov     w21, #0x48          // 'H' for Halt
    str     w21, [x20]
    b       .
