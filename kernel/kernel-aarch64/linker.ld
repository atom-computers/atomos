PAGE_SIZE = 4K;
PAGE_MASK = PAGE_SIZE - 1;

ENTRY(_start)

SECTIONS
{
    . = 0x40080000;

    __image_start = .;

    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : { *(.rodata .rodata.*) }

    .data : { *(.data .data.*) }

    .bss : {
        . = ALIGN(16);
        __bss_start = .;
        *(.bss .bss.*)
        . = ALIGN(16);
        __bss_end = .;
    }

    . = ALIGN(16);
    __boot_stack_bottom = .;
    . += 64K;
    __boot_stack_top = .;

    __image_end = .;
}
