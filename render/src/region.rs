use kernel_spec::{ElementFormat, Kernel, KernelError, Region, RegionId, RegionKind};

pub struct RegionSurface<'k> {
    kernel: &'k dyn Kernel,
    id: RegionId,
    pub info: Region,
}

impl<'k> RegionSurface<'k> {
    pub fn open(kernel: &'k dyn Kernel, id: RegionId) -> Result<Self, KernelError> {
        let info = kernel.region_info(id)?;
        Ok(RegionSurface { kernel, id, info })
    }

    pub fn id(&self) -> RegionId {
        self.id
    }

    /// Get the Spatial dimensions (x, y, z, t) if this is a Spatial region.
    pub fn spatial_dims(&self) -> Option<(u32, u32, u32, u32)> {
        match &self.info.kind {
            RegionKind::Spatial { x, y, z, t, .. } => Some((*x, *y, *z, *t)),
            _ => None,
        }
    }

    /// Get the element format if this is a Spatial region.
    pub fn element_format(&self) -> Option<ElementFormat> {
        match &self.info.kind {
            RegionKind::Spatial { format, .. } => Some(*format),
            _ => None,
        }
    }

    /// Compute the byte offset for an element at (x, y, z, t).
    ///
    /// Elements are laid out in (t, z, y, x) row-major order: t is the outermost
    /// dimension, x is the innermost. Returns `None` if any coordinate exceeds bounds.
    pub fn element_offset(&self, x: u32, y: u32, z: u32, t: u32) -> Option<usize> {
        let (sx, sy, sz, st) = self.spatial_dims()?;
        let elem_size = self.element_format()?.byte_size();
        if x >= sx || y >= sy || z >= sz || t >= st {
            return None;
        }
        let frame_elems = sz as usize * sy as usize * sx as usize;
        let slice_elems = sy as usize * sx as usize;
        let row_elems = sx as usize;
        let offset_elems =
            t as usize * frame_elems + z as usize * slice_elems + y as usize * row_elems
                + x as usize;
        Some(offset_elems * elem_size)
    }

    /// Read a single element at (x, y, z, t) into a buffer sized for one element.
    pub fn read_element(
        &self,
        x: u32,
        y: u32,
        z: u32,
        t: u32,
    ) -> Result<alloc::vec::Vec<u8>, KernelError> {
        let offset = self
            .element_offset(x, y, z, t)
            .ok_or(KernelError::InvalidArgument)?;
        let elem_size = self
            .element_format()
            .ok_or(KernelError::InvalidArgument)?
            .byte_size();
        let mut buf = alloc::vec![0u8; elem_size];
        self.kernel.read_region(self.id, offset, &mut buf)?;
        Ok(buf)
    }

    /// Write a single element at (x, y, z, t).
    pub fn write_element(
        &self,
        x: u32,
        y: u32,
        z: u32,
        t: u32,
        data: &[u8],
    ) -> Result<(), KernelError> {
        let offset = self
            .element_offset(x, y, z, t)
            .ok_or(KernelError::InvalidArgument)?;
        self.kernel.write_region(self.id, offset, data)?;
        Ok(())
    }

    /// Write a single pixel (U8x4 element) at (x, y, z, t).
    pub fn write_pixel(
        &self,
        x: u32,
        y: u32,
        z: u32,
        t: u32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    ) -> Result<(), KernelError> {
        self.write_element(x, y, z, t, &[r, g, b, a])
    }

    /// Read raw bytes from the region at the given byte offset.
    pub fn read_bytes(&self, offset: usize, buf: &mut [u8]) -> Result<usize, KernelError> {
        self.kernel.read_region(self.id, offset, buf)
    }

    /// Write raw bytes to the region at the given byte offset.
    pub fn write_bytes(&self, offset: usize, data: &[u8]) -> Result<usize, KernelError> {
        self.kernel.write_region(self.id, offset, data)
    }

    /// Fill the entire region with a byte value (for clearing).
    pub fn fill(&self, value: u8) -> Result<(), KernelError> {
        let size = self.info.size;
        // Write in chunks to avoid large allocations
        let chunk = [value; 4096];
        let mut offset = 0;
        while offset < size {
            let remaining = size - offset;
            let write_len = core::cmp::min(chunk.len(), remaining);
            self.kernel
                .write_region(self.id, offset, &chunk[..write_len])?;
            offset += write_len;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use alloc::vec;
    use super::*;
    use kernel_mock::MockKernel;
    use kernel_spec::{Kernel, MemoryTier, RegionKind};

    #[test]
    fn element_offset_flat_2d() {
        let kernel = MockKernel::new();
        let id = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 4,
                    y: 3,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                48, // 4*3*1*1*4
                MemoryTier::ShortTerm,
                Some("test-surface"),
            )
            .unwrap();

        let surface = RegionSurface::open(&kernel, id).unwrap();

        // Row 0, col 0 → byte 0
        assert_eq!(surface.element_offset(0, 0, 0, 0), Some(0));
        // Row 0, col 1 → byte 4
        assert_eq!(surface.element_offset(1, 0, 0, 0), Some(4));
        // Row 0, col 3 → byte 12
        assert_eq!(surface.element_offset(3, 0, 0, 0), Some(12));
        // Row 1, col 0 → byte 16 (4 pixels * 4 bytes * 1 row)
        assert_eq!(surface.element_offset(0, 1, 0, 0), Some(16));
        // Row 2, col 3 → byte 44
        assert_eq!(surface.element_offset(3, 2, 0, 0), Some(44));
    }

    #[test]
    fn element_offset_out_of_bounds() {
        let kernel = MockKernel::new();
        let id = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 4,
                    y: 3,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                48,
                MemoryTier::ShortTerm,
                Some("test-surface"),
            )
            .unwrap();

        let surface = RegionSurface::open(&kernel, id).unwrap();

        assert_eq!(surface.element_offset(4, 0, 0, 0), None); // x out of bounds
        assert_eq!(surface.element_offset(0, 3, 0, 0), None); // y out of bounds
        assert_eq!(surface.element_offset(0, 0, 1, 0), None); // z out of bounds
        assert_eq!(surface.element_offset(0, 0, 0, 1), None); // t out of bounds
    }

    #[test]
    fn write_and_read_pixel() {
        let kernel = MockKernel::new();
        let id = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 2,
                    y: 2,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                16,
                MemoryTier::ShortTerm,
                Some("test-fb"),
            )
            .unwrap();

        let surface = RegionSurface::open(&kernel, id).unwrap();

        surface.write_pixel(0, 0, 0, 0, 255, 128, 64, 32).unwrap();
        surface
            .write_pixel(1, 1, 0, 0, 10, 20, 30, 40)
            .unwrap();

        let p0 = surface.read_element(0, 0, 0, 0).unwrap();
        assert_eq!(p0, vec![255, 128, 64, 32]);

        let p1 = surface.read_element(1, 1, 0, 0).unwrap();
        assert_eq!(p1, vec![10, 20, 30, 40]);
    }

    #[test]
    fn region_info_matches() {
        let kernel = MockKernel::new();
        let id = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 100,
                    y: 200,
                    z: 1,
                    t: 2,
                    format: ElementFormat::U8x4,
                },
                160000,
                MemoryTier::ShortTerm,
                Some("display"),
            )
            .unwrap();

        let surface = RegionSurface::open(&kernel, id).unwrap();
        let dims = surface.spatial_dims().unwrap();
        assert_eq!(dims, (100, 200, 1, 2));
        assert_eq!(surface.element_format(), Some(ElementFormat::U8x4));
    }

    #[test]
    fn raw_region_has_no_spatial_dims() {
        let kernel = MockKernel::new();
        let id = kernel
            .create_region(
                RegionKind::Raw,
                256,
                MemoryTier::ShortTerm,
                Some("raw-data"),
            )
            .unwrap();

        let surface = RegionSurface::open(&kernel, id).unwrap();
        assert_eq!(surface.spatial_dims(), None);
        assert_eq!(surface.element_format(), None);
    }
}
