use kernel_spec::{ElementFormat, Kernel, KernelError, RegionId};

use crate::region::RegionSurface;

/// Alpha-blend `src` onto `dst` using the "src-over-dst" compositing operator.
///
/// Both regions must be `Spatial { format: U8x4 }` with matching dimensions.
/// The result is written back into `dst`.
///
/// For each pixel: `result = src_color * src_alpha + dst_color * (1 - src_alpha)`.
pub fn blend(
    kernel: &dyn Kernel,
    src: RegionId,
    dst: RegionId,
) -> Result<(), KernelError> {
    let src_surface = RegionSurface::open(kernel, src)?;
    let dst_surface = RegionSurface::open(kernel, dst)?;

    if src_surface.element_format() != Some(ElementFormat::U8x4)
        || dst_surface.element_format() != Some(ElementFormat::U8x4)
    {
        return Err(KernelError::InvalidArgument);
    }

    let src_dims = src_surface
        .spatial_dims()
        .ok_or(KernelError::InvalidArgument)?;
    let dst_dims = dst_surface
        .spatial_dims()
        .ok_or(KernelError::InvalidArgument)?;

    if src_dims != dst_dims {
        return Err(KernelError::InvalidArgument);
    }

    let (sx, sy, sz, st) = src_dims;

    for t in 0..st {
        for z in 0..sz {
            for y in 0..sy {
                for x in 0..sx {
                    let src_px = src_surface.read_element(x, y, z, t)?;
                    let dst_px = dst_surface.read_element(x, y, z, t)?;

                    let sa = src_px[3] as f32 / 255.0;

                    let r = (src_px[0] as f32 * sa + dst_px[0] as f32 * (1.0 - sa)) as u8;
                    let g = (src_px[1] as f32 * sa + dst_px[1] as f32 * (1.0 - sa)) as u8;
                    let b = (src_px[2] as f32 * sa + dst_px[2] as f32 * (1.0 - sa)) as u8;
                    let a = (src_px[3] as f32 + dst_px[3] as f32 * (1.0 - sa)).min(255.0) as u8;

                    dst_surface.write_pixel(x, y, z, t, r, g, b, a)?;
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use alloc::vec;
    use super::*;
    use kernel_mock::MockKernel;
    use kernel_spec::{Kernel, MemoryTier, RegionKind};

    #[test]
    fn blend_solid_over_clear() {
        let kernel = MockKernel::new();

        let src = kernel
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
                Some("src"),
            )
            .unwrap();

        let dst = kernel
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
                Some("dst"),
            )
            .unwrap();

        // Fill src with red at 50% opacity
        let src_surface = RegionSurface::open(&kernel, src).unwrap();
        let dst_surface = RegionSurface::open(&kernel, dst).unwrap();
        for y in 0..2 {
            for x in 0..2 {
                src_surface.write_pixel(x, y, 0, 0, 255, 0, 0, 128).unwrap();
                dst_surface
                    .write_pixel(x, y, 0, 0, 0, 0, 0, 0)
                    .unwrap();
            }
        }

        blend(&kernel, src, dst).unwrap();

        // After blending: red at 50% opacity over black → dark red
        let result = dst_surface.read_element(0, 0, 0, 0).unwrap();
        // r ≈ 128 (255 * 0.5 + 0 * 0.5)
        assert!((result[0] as i32 - 128).abs() <= 1);
        assert_eq!(result[1], 0);
        assert_eq!(result[2], 0);
        // alpha ≈ 128 (128 + 0 * 0.5)
        assert!((result[3] as i32 - 128).abs() <= 1);
    }

    #[test]
    fn blend_full_opaque_overwrites() {
        let kernel = MockKernel::new();

        let src = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 1,
                    y: 1,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                4,
                MemoryTier::ShortTerm,
                Some("src"),
            )
            .unwrap();

        let dst = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 1,
                    y: 1,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                4,
                MemoryTier::ShortTerm,
                Some("dst"),
            )
            .unwrap();

        let src_surface = RegionSurface::open(&kernel, src).unwrap();
        let dst_surface = RegionSurface::open(&kernel, dst).unwrap();

        src_surface
            .write_pixel(0, 0, 0, 0, 10, 20, 30, 255)
            .unwrap();
        dst_surface
            .write_pixel(0, 0, 0, 0, 100, 200, 50, 255)
            .unwrap();

        blend(&kernel, src, dst).unwrap();

        let result = dst_surface.read_element(0, 0, 0, 0).unwrap();
        // Opaque src should completely replace dst
        assert_eq!(result, vec![10, 20, 30, 255]);
    }
}
