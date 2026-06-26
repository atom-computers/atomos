use core::ptr::read_unaligned;

const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

pub struct FdtReader {
    base: *const u8,
    strings: *const u8,
    struct_start: *const u8,
    struct_end: *const u8,
}

impl FdtReader {
    pub fn new(fdt_ptr: *const u8) -> Option<Self> {
        if fdt_ptr.is_null() {
            return None;
        }
        let magic = read_u32(fdt_ptr);
        if magic != 0xd00dfeed {
            return None;
        }
        // FDT header layout:
        // 0x00: magic (4)
        // 0x04: totalsize (4)
        // 0x08: off_dt_struct (4)
        // 0x0c: off_dt_strings (4)
        let off_struct = read_u32(unsafe { fdt_ptr.add(8) }) as usize;
        let off_strings = read_u32(unsafe { fdt_ptr.add(12) }) as usize;

        Some(FdtReader {
            base: fdt_ptr,
            strings: unsafe { fdt_ptr.add(off_strings) },
            struct_start: unsafe { fdt_ptr.add(off_struct) },
            // Struct block ends before strings block
            struct_end: unsafe { fdt_ptr.add(off_strings) },
        })
    }

    pub fn walk(&self, cb: &dyn Fn(&str, u64, u64)) {
        let mut pos = self.struct_start as usize;
        let end = self.struct_end as usize;
        let mut depth: usize = 0;
        let mut iters: u32 = 0;

        let mut current_addr: u64 = 0;
        let mut current_size: u64 = 0;
        let mut current_compat: Option<&str> = None;
        let mut current_name: &str = "?";
        let max_iters: u32 = 500;

        while pos < end {
            iters += 1;
            if iters > max_iters {
                break;
            }

            let token = read_u32(pos as *const u8);
            pos += 4;

            unsafe {
                match token {
                    FDT_BEGIN_NODE => {
                        if pos >= end {
                            break;
                        }
                        let start = pos as *const u8;
                        let mut p = pos;
                        while p < end && *(p as *const u8) != 0 {
                            p += 1;
                        }
                        let len = p - pos;
                        let name_slice = core::slice::from_raw_parts(start, len);
                        current_name = core::str::from_utf8(name_slice).unwrap_or("?");
                        pos = p + 1; // skip null
                        pos = align4(pos);
                        depth += 1;
                        current_compat = None;
                        current_addr = 0;
                        current_size = 0;
                    }
                    FDT_END_NODE => {
                        if depth > 0 {
                            depth -= 1;
                        }
                    }
                    FDT_PROP => {
                        if pos + 8 > end {
                            break;
                        }
                        let len = read_u32(pos as *const u8) as usize;
                        pos += 4;
                        let nameoff = read_u32(pos as *const u8) as usize;
                        pos += 4;

                        let prop_name = self.string_at(nameoff);
                        let data_end = pos + len;
                        let aligned_end = align4(data_end);

                        if data_end > end || aligned_end > end {
                            break;
                        }

                        match prop_name {
                            "compatible" if len > 0 => {
                                let data = core::slice::from_raw_parts(pos as *const u8, len);
                                let compat_str =
                                    core::str::from_utf8(data).unwrap_or("");
                                let first = compat_str.split('\0').next().unwrap_or("");
                                current_compat = Some(first);
                            }
                    "reg" => {
                        if len >= 16 {
                            let cell0 =
                                read_u32(pos as *const u8) as u64;
                            let cell1 =
                                read_u32((pos as *const u8).add(4)) as u64;

                            current_addr = (cell0 << 32) | cell1;

                            let size_hi =
                                read_u32((pos as *const u8).add(8)) as u64;
                            let size_lo =
                                read_u32((pos as *const u8).add(12)) as u64;
                            current_size = (size_hi << 32) | size_lo;

                            // For PCI nodes, the reg encodes PCI config space, not
                            // a physical address. Extract the ECAM base from the
                            // node name (e.g. "pcie@10000000" → 0x10000000).
                            if current_name.starts_with("pci") {
                                if let Some(at_pos) = current_name.find('@') {
                                    let addr_str = &current_name[at_pos + 1..];
                                    if let Ok(parsed) = u64::from_str_radix(addr_str, 16) {
                                        current_addr = parsed;
                                    }
                                }
                            }
                        }
                    }
                            _ => {}
                        }

                        pos = aligned_end;

                        if let Some(_compat) = current_compat {
                            if current_addr != 0 {
                                cb(current_name, current_addr, current_size);
                                current_compat = None;
                            }
                        }
                    }
                    FDT_NOP => {}
                    FDT_END => break,
                    _ => break,
                }
            }
        }
    }

    fn string_at(&self, offset: usize) -> &str {
        let p = unsafe { self.strings.add(offset) };
        let mut len = 0;
        unsafe {
            while *p.add(len) != 0 {
                len += 1;
            }
            core::str::from_utf8_unchecked(core::slice::from_raw_parts(p, len))
        }
    }
}

fn read_u32(ptr: *const u8) -> u32 {
    unsafe { u32::from_be(read_unaligned(ptr as *const u32)) }
}

fn align4(addr: usize) -> usize {
    (addr + 3) & !3
}
