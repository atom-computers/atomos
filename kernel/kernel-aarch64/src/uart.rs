use core::ptr::{read_volatile, write_volatile};

const UART0_BASE: usize = 0x0900_0000;

const UART_DR: usize = UART0_BASE + 0x000;
const UART_FR: usize = UART0_BASE + 0x018;
const UART_IBRD: usize = UART0_BASE + 0x024;
const UART_FBRD: usize = UART0_BASE + 0x028;
const UART_LCRH: usize = UART0_BASE + 0x02C;
const UART_CR: usize = UART0_BASE + 0x030;

const FR_TXFF: u32 = 1 << 5;

pub fn init() {
    unsafe {
        // Disable UART
        write_volatile(UART_CR as *mut u32, 0);

        // Set baud rate to 115200 with 24MHz clock
        // IBRD = 24000000 / (16 * 115200) = 13
        // FBRD = fractional part * 64 + 0.5 = (0.0208) * 64 + 0.5 ≈ 1
        write_volatile(UART_IBRD as *mut u32, 13);
        write_volatile(UART_FBRD as *mut u32, 1);

        // 8N1, enable FIFO
        write_volatile(UART_LCRH as *mut u32, 0x3 << 5);

        // Enable UART, TX, RX
        write_volatile(UART_CR as *mut u32, (1 << 0) | (1 << 8) | (1 << 9));
    }
}

pub fn putc(c: u8) {
    unsafe {
        // Wait for TX FIFO to have space
        while read_volatile(UART_FR as *mut u32) & FR_TXFF != 0 {}
        write_volatile(UART_DR as *mut u32, c as u32);
    }
}

pub fn puts(s: &str) {
    for c in s.bytes() {
        if c == b'\n' {
            putc(b'\r');
        }
        putc(c);
    }
}

#[allow(dead_code)]
pub fn puthex(mut val: u64) {
    puts("0x");
    if val == 0 {
        putc(b'0');
        return;
    }
    let mut buf = [0u8; 16];
    let mut i = 0;
    while val > 0 {
        let nibble = (val & 0xF) as u8;
        buf[i] = if nibble < 10 { b'0' + nibble } else { b'a' + (nibble - 10) };
        val >>= 4;
        i += 1;
    }
    while i > 0 {
        i -= 1;
        putc(buf[i]);
    }
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = write!(&mut $crate::uart::UartWriter, $($arg)*);
    }};
}

#[macro_export]
macro_rules! println {
    () => { $crate::uart::puts("\n"); };
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = write!(&mut $crate::uart::UartWriter, $($arg)*);
        $crate::uart::puts("\n");
    }};
}

pub struct UartWriter;

impl core::fmt::Write for UartWriter {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        puts(s);
        Ok(())
    }
}
