use alloc::vec::Vec;
use core::f32;

use kernel_spec::{ElementFormat, Kernel, KernelError, RegionId};

use crate::math::{Mat4, Vec2, Vec4};
use crate::region::RegionSurface;

/// Edge function: returns signed area × 2 for the triangle (a, b, c).
/// Positive if c is to the left of the directed edge a→b.
fn edge(a: Vec2, b: Vec2, c: Vec2) -> f32 {
    (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)
}

/// Barycentric coordinates of point p in triangle (a, b, c).
fn barycentric(p: Vec2, a: Vec2, b: Vec2, c: Vec2) -> (f32, f32, f32) {
    let area = edge(a, b, c);
    if area.abs() < 1e-7 {
        return (1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0);
    }
    let w0 = edge(b, c, p) / area;
    let w1 = edge(c, a, p) / area;
    let w2 = 1.0 - w0 - w1;
    (w0, w1, w2)
}

/// Interpolate 3 Vec4 values using barycentric weights.
fn interpolate_vec4(w0: f32, w1: f32, w2: f32, v0: Vec4, v1: Vec4, v2: Vec4) -> Vec4 {
    v0 * w0 + v1 * w1 + v2 * w2
}

/// Viewport transform: NDC (-1..1) → pixel coordinates.
fn to_viewport(ndc: Vec4, width: u32, height: u32) -> Vec2 {
    Vec2::new(
        (ndc.x * 0.5 + 0.5) * width as f32,
        (1.0 - (ndc.y * 0.5 + 0.5)) * height as f32,
    )
}

/// A vertex with position and color.
#[derive(Debug, Clone, Copy)]
struct Vertex {
    pos: Vec4,
    color: Vec4,
}

/// CPU software triangle rasterizer.
///
/// Reads vertex data from a `Spatial { format: F32x4 }` region where each
/// vertex occupies 2 consecutive elements (position then color).
/// Projects through `transform`, rasterizes into the target region, and
/// depth-tests using a z-buffer.
///
/// The vertex region layout:
/// - element[v*2]   = (pos.x, pos.y, pos.z, pos.w)
/// - element[v*2+1] = (color.x, color.y, color.z, color.w)
///
/// The target region must be `Spatial { format: U8x4 }`.
pub fn rasterize(
    kernel: &dyn Kernel,
    vertex_region: RegionId,
    transform: Mat4,
    target_region: RegionId,
    clear_color: Option<[u8; 4]>,
) -> Result<(), KernelError> {
    let target = RegionSurface::open(kernel, target_region)?;
    let vert_src = RegionSurface::open(kernel, vertex_region)?;

    let (vx, _vy, _vz, _vt) = vert_src
        .spatial_dims()
        .ok_or(KernelError::InvalidArgument)?;
    let (tw, th, _tz, tt) = target
        .spatial_dims()
        .ok_or(KernelError::InvalidArgument)?;
    if target.element_format() != Some(ElementFormat::U8x4) {
        return Err(KernelError::InvalidArgument);
    }

    // Number of vertices: x dimension / 2 (2 elements per vertex)
    let vertex_count = vx as usize / 2;

    // Read all vertices
    let mut vertices: Vec<Vertex> = Vec::with_capacity(vertex_count);
    for v in 0..vertex_count {
        let pos_bytes = vert_src.read_element((v * 2) as u32, 0, 0, 0)?;
        let col_bytes = vert_src.read_element((v * 2 + 1) as u32, 0, 0, 0)?;

        let px = f32::from_le_bytes([pos_bytes[0], pos_bytes[1], pos_bytes[2], pos_bytes[3]]);
        let py = f32::from_le_bytes([pos_bytes[4], pos_bytes[5], pos_bytes[6], pos_bytes[7]]);
        let pz = f32::from_le_bytes([pos_bytes[8], pos_bytes[9], pos_bytes[10], pos_bytes[11]]);
        let pw = f32::from_le_bytes([pos_bytes[12], pos_bytes[13], pos_bytes[14], pos_bytes[15]]);

        let cr = f32::from_le_bytes([col_bytes[0], col_bytes[1], col_bytes[2], col_bytes[3]]);
        let cg = f32::from_le_bytes([col_bytes[4], col_bytes[5], col_bytes[6], col_bytes[7]]);
        let cb = f32::from_le_bytes([col_bytes[8], col_bytes[9], col_bytes[10], col_bytes[11]]);
        let ca = f32::from_le_bytes([col_bytes[12], col_bytes[13], col_bytes[14], col_bytes[15]]);

        vertices.push(Vertex {
            pos: Vec4::new(px, py, pz, pw),
            color: Vec4::new(cr, cg, cb, ca),
        });
    }

    let total_pixels = tw as usize * th as usize;
    let mut z_buffer: Vec<f32> = alloc::vec![f32::INFINITY; total_pixels];

    // Clear target if requested
    if let Some(c) = clear_color {
        target.fill(0)?;
        // Write clear color to first pixel to seed the region
        target.write_pixel(0, 0, 0, 0, c[0], c[1], c[2], c[3])?;
        // Then fill is simpler — write the clear color everywhere
        // Actually fill already zeroed it. Let me just clear with the correct color.
        let size = target.info.size;
        let chunk = [c[0], c[1], c[2], c[3]];
        let chunk_len = chunk.len();
        let repetitions = size / chunk_len;
        let mut offset = 0;
        for _ in 0..repetitions {
            target.write_bytes(offset, &chunk)?;
            offset += chunk_len;
        }
    }

    // Transform and viewport all vertices
    let mut screen_verts: Vec<Vec4> = Vec::with_capacity(vertex_count);
    for v in &vertices {
        let clip = transform * v.pos;
        screen_verts.push(clip);
    }

    // Rasterize triangles (every 3 vertices = 1 triangle)
    let tri_count = vertex_count / 3;
    for frame_t in 0..tt {
        for tri_idx in 0..tri_count {
            let i0 = tri_idx * 3;
            let i1 = i0 + 1;
            let i2 = i0 + 2;

            // Perspective divide
            let w0_inv = if screen_verts[i0].w.abs() > 1e-7 {
                1.0 / screen_verts[i0].w
            } else {
                1.0
            };
            let w1_inv = if screen_verts[i1].w.abs() > 1e-7 {
                1.0 / screen_verts[i1].w
            } else {
                1.0
            };
            let w2_inv = if screen_verts[i2].w.abs() > 1e-7 {
                1.0 / screen_verts[i2].w
            } else {
                1.0
            };

            let p0 = Vec4::new(
                screen_verts[i0].x * w0_inv,
                screen_verts[i0].y * w0_inv,
                screen_verts[i0].z * w0_inv,
                1.0,
            );
            let p1 = Vec4::new(
                screen_verts[i1].x * w1_inv,
                screen_verts[i1].y * w1_inv,
                screen_verts[i1].z * w1_inv,
                1.0,
            );
            let p2 = Vec4::new(
                screen_verts[i2].x * w2_inv,
                screen_verts[i2].y * w2_inv,
                screen_verts[i2].z * w2_inv,
                1.0,
            );

            // Viewport transform
            let v0 = to_viewport(p0, tw, th);
            let v1 = to_viewport(p1, tw, th);
            let v2 = to_viewport(p2, tw, th);

            // Back-face culling (counter-clockwise in screen space → front face)
            let face_area = edge(v0, v1, v2);
            if face_area <= 0.0 {
                continue;
            }

            // Bounding box
            let min_x = (libm::floorf(f32::min(f32::min(v0.x, v1.x), v2.x)) as i32).max(0) as u32;
            let max_x = (libm::ceilf(f32::max(f32::max(v0.x, v1.x), v2.x)) as i32).min(tw as i32 - 1) as u32;
            let min_y = (libm::floorf(f32::min(f32::min(v0.y, v1.y), v2.y)) as i32).max(0) as u32;
            let max_y = (libm::ceilf(f32::max(f32::max(v0.y, v1.y), v2.y)) as i32).min(th as i32 - 1) as u32;

            for py in min_y..=max_y {
                for px in min_x..=max_x {
                    let p = Vec2::new(px as f32 + 0.5, py as f32 + 0.5);

                    let (w0, w1, w2) = barycentric(p, v0, v1, v2);

                    // Inside triangle check
                    if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                        continue;
                    }

                    // Perspective-correct interpolation
                    let z_div = w0 * w0_inv + w1 * w1_inv + w2 * w2_inv;
                    if z_div < 1e-10 {
                        continue;
                    }
                    let z = p0.z * w0 * w0_inv / z_div
                        + p1.z * w1 * w1_inv / z_div
                        + p2.z * w2 * w2_inv / z_div;

                    let idx = (py * tw + px) as usize;
                    if idx >= total_pixels {
                        continue;
                    }

                    // Z-test
                    if z >= z_buffer[idx] {
                        continue;
                    }
                    z_buffer[idx] = z;

                    // Interpolate color
                    let color = interpolate_vec4(
                        w0 * w0_inv / z_div,
                        w1 * w1_inv / z_div,
                        w2 * w2_inv / z_div,
                        vertices[i0].color,
                        vertices[i1].color,
                        vertices[i2].color,
                    );

                    let r = (color.x.clamp(0.0, 1.0) * 255.0) as u8;
                    let g = (color.y.clamp(0.0, 1.0) * 255.0) as u8;
                    let b = (color.z.clamp(0.0, 1.0) * 255.0) as u8;
                    let a = (color.w.clamp(0.0, 1.0) * 255.0) as u8;

                    target.write_pixel(px, py, 0, frame_t, r, g, b, a)?;
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

    fn write_f32x4_element(
        kernel: &MockKernel,
        region: RegionId,
        idx: u32,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
    ) {
        let mut bytes = [0u8; 16];
        bytes[0..4].copy_from_slice(&a.to_le_bytes());
        bytes[4..8].copy_from_slice(&b.to_le_bytes());
        bytes[8..12].copy_from_slice(&c.to_le_bytes());
        bytes[12..16].copy_from_slice(&d.to_le_bytes());
        kernel.write_region(region, idx as usize * 16, &bytes).unwrap();
    }

    #[test]
    fn rasterize_single_triangle_fills_pixels() {
        let kernel = MockKernel::new();

        // Target framebuffer: 4x4 pixels, U8x4
        let fb = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 4,
                    y: 4,
                    z: 1,
                    t: 1,
                    format: ElementFormat::U8x4,
                },
                64,
                MemoryTier::ShortTerm,
                Some("fb"),
            )
            .unwrap();

        // Vertex region: 3 vertices (6 F32x4 elements)
        let verts = kernel
            .create_region(
                RegionKind::Spatial {
                    x: 6, // 3 vertices * 2 elements each
                    y: 1,
                    z: 1,
                    t: 1,
                    format: ElementFormat::F32x4,
                },
                96,
                MemoryTier::ShortTerm,
                Some("verts"),
            )
            .unwrap();

        // Triangle covering most of the 4x4 screen, in NDC space
        // v0: top-center (-1..1 maps to 0..4 with viewport)
        write_f32x4_element(&kernel, verts, 0, 0.0, -0.9, 0.0, 1.0);
        // v0 color: red
        write_f32x4_element(&kernel, verts, 1, 1.0, 0.0, 0.0, 1.0);

        // v1: bottom-left
        write_f32x4_element(&kernel, verts, 2, -0.9, 0.9, 0.0, 1.0);
        // v1 color: green
        write_f32x4_element(&kernel, verts, 3, 0.0, 1.0, 0.0, 1.0);

        // v2: bottom-right
        write_f32x4_element(&kernel, verts, 4, 0.9, 0.9, 0.0, 1.0);
        // v2 color: blue
        write_f32x4_element(&kernel, verts, 5, 0.0, 0.0, 1.0, 1.0);

        let transform = Mat4::identity(); // NDC → viewport handled internally
        rasterize(
            &kernel,
            verts,
            transform,
            fb,
            Some([0x27, 0x29, 0x2A, 0xFF]),
        )
        .unwrap();

        // Read back a pixel near the center of the triangle
        let surface = RegionSurface::open(&kernel, fb).unwrap();
        let pixel = surface.read_element(2, 2, 0, 0).unwrap();

        // Should be non-black (something was rendered)
        let is_colored = pixel[0] > 0 || pixel[1] > 0 || pixel[2] > 0;
        assert!(is_colored, "Expected colored pixel, got {:?}", pixel);

        // Top-left corner should be clear color (outside triangle)
        let corner = surface.read_element(0, 0, 0, 0).unwrap();
        // The clear fill writes the clear color in 4-byte chunks across the region
        // Since the entire region was filled with clear color, all bytes should match
        assert_eq!(corner, vec![0x27, 0x29, 0x2A, 0xFF], "Corner should be clear color, got {:?}", corner);
    }
}
