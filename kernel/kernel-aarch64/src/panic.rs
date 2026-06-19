use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    crate::uart::puts("\nKERNEL PANIC: ");
    crate::uart::puts("(panic occurred)");
    loop {
        core::hint::spin_loop();
    }
}
