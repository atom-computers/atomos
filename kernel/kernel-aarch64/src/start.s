.section ".text._start", "ax"
.globl _start

_start:
    // QEMU starts with MMU off. x0 = FDT pointer.

    mov     x19, x0           // save FDT pointer

    // Drop to EL1 if booted at a higher exception level
    mrs     x20, CurrentEL
    lsr     x20, x20, #2      // shift to get EL number (1, 2, or 3)
    cmp     x20, #1
    b.eq    1f                // already at EL1

    // EL2 → EL1 transition
    // Set HCR_EL2: RW=1 (lower EL is AArch64)
    mov     x20, #(1 << 31)
    msr     hcr_el2, x20
    // SPSR_EL2: return to EL1h, all exceptions masked
    mov     x20, #0x3c5       // DAIF=1111, M[3:0]=0101 (EL1h)
    msr     spsr_el2, x20
    // Return address
    adr     x20, 1f
    msr     elr_el2, x20
    eret

1:
    // Zero .bss
    adr     x1, __bss_start
    adr     x2, __bss_end
2:  cmp     x1, x2
    b.eq    3f
    stp     xzr, xzr, [x1], #16
    b       2b

    // Set up boot stack
3:  adr     x0, __boot_stack_top
    mov     sp, x0

    // Mask IRQs and FIQs
    msr     daifset, #0b0110

    // Set VBAR to exception vector table
    adr     x20, exception_vector_table
    msr     vbar_el1, x20
    isb

    // Jump to Rust entry
    mov     x0, x19            // pass FDT pointer
    bl      kernel_main

    // If kernel_main returns, halt
4:  wfe
    b       4b

// Exception vector table — 2KB aligned, 16 entries × 128 bytes each
.balign 0x800
.globl exception_vector_table
exception_vector_table:

    // 0x000: Current EL with SP0 — sync
    b       unhandled_exception
    .balign 0x80
    // 0x080: Current EL with SP0 — IRQ
    b       unhandled_exception
    .balign 0x80
    // 0x100: Current EL with SP0 — FIQ
    b       unhandled_exception
    .balign 0x80
    // 0x180: Current EL with SP0 — SError
    b       unhandled_exception

    // 0x200: Current EL with SPx — sync
    .balign 0x80
    b       sync_el1h_handler
    .balign 0x80
    // 0x280: Current EL with SPx — IRQ
    b       irq_handler
    .balign 0x80
    // 0x300: Current EL with SPx — FIQ
    b       irq_handler
    .balign 0x80
    // 0x380: Current EL with SPx — SError
    b       unhandled_exception

    // 0x400: Lower EL using AArch64 — sync
    .balign 0x80
    b       sync_el0_64_handler
    .balign 0x80
    // 0x480: Lower EL using AArch64 — IRQ
    b       irq_handler
    .balign 0x80
    // 0x500: Lower EL using AArch64 — FIQ
    b       irq_handler
    .balign 0x80
    // 0x580: Lower EL using AArch64 — SError
    b       unhandled_exception

    // 0x600: Lower EL using AArch32 — unused
    .balign 0x80
    b       unhandled_exception
    .balign 0x80
    .balign 0x80
    .balign 0x80

// Sync exception from EL1 (current EL with SPx)
sync_el1h_handler:
    stp     x29, x30, [sp, #-16]!
    stp     x0,  x1,  [sp, #-16]!
    stp     x2,  x3,  [sp, #-16]!
    stp     x4,  x5,  [sp, #-16]!
    stp     x6,  x7,  [sp, #-16]!

    mrs     x0, esr_el1
    mrs     x1, far_el1
    mrs     x2, elr_el1
    bl      handle_sync_exception

    ldp     x6,  x7,  [sp], #16
    ldp     x4,  x5,  [sp], #16
    ldp     x2,  x3,  [sp], #16
    ldp     x0,  x1,  [sp], #16
    ldp     x29, x30, [sp], #16
    eret

// Sync exception from EL0 (lower EL, AArch64)
sync_el0_64_handler:
    stp     x29, x30, [sp, #-16]!
    stp     x0,  x1,  [sp, #-16]!
    stp     x2,  x3,  [sp, #-16]!
    stp     x4,  x5,  [sp, #-16]!
    stp     x6,  x7,  [sp, #-16]!

    mrs     x0, esr_el1
    mrs     x1, far_el1
    mrs     x2, elr_el1
    bl      handle_el0_fault

    ldp     x6,  x7,  [sp], #16
    ldp     x4,  x5,  [sp], #16
    ldp     x2,  x3,  [sp], #16
    ldp     x0,  x1,  [sp], #16
    ldp     x29, x30, [sp], #16
    eret

// IRQ/FIQ handler — just return
irq_handler:
    eret

// Catch-all for unhandled exceptions
unhandled_exception:
    b       .
