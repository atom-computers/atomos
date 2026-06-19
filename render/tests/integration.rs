use kernel_mock::MockKernel;
use kernel_spec::{ElementFormat, Kernel, MemoryTier, RegionKind};
use render::math::Mat4;
use render::rasterize::rasterize;
use render::region::RegionSurface;

fn write_f32x4(bytes: &mut [u8], a: f32, b: f32, c: f32, d: f32) {
    bytes[0..4].copy_from_slice(&a.to_le_bytes());
    bytes[4..8].copy_from_slice(&b.to_le_bytes());
    bytes[8..12].copy_from_slice(&c.to_le_bytes());
    bytes[12..16].copy_from_slice(&d.to_le_bytes());
}

fn write_vertex(kernel: &MockKernel, verts: kernel_spec::RegionId, idx: u32, pos: (f32, f32, f32, f32), color: (f32, f32, f32, f32)) {
    let offset = idx as usize * 2 * 16;
    let mut pos_bytes = [0u8; 16];
    let mut col_bytes = [0u8; 16];
    write_f32x4(&mut pos_bytes, pos.0, pos.1, pos.2, pos.3);
    write_f32x4(&mut col_bytes, color.0, color.1, color.2, color.3);
    kernel.write_region(verts, offset, &pos_bytes).unwrap();
    kernel.write_region(verts, offset + 16, &col_bytes).unwrap();
}

#[test]
fn render_colored_quad() {
    let kernel = MockKernel::new();

    // 8x8 framebuffer
    let fb = kernel
        .create_region(
            RegionKind::Spatial {
                x: 8,
                y: 8,
                z: 1,
                t: 1,
                format: ElementFormat::U8x4,
            },
            256, // 8*8*4
            MemoryTier::ShortTerm,
            Some("framebuffer"),
        )
        .unwrap();

    // 6 vertices = 2 triangles forming a quad that covers the full 8x8 area
    let verts = kernel
        .create_region(
            RegionKind::Spatial {
                x: 12, // 6 vertices * 2 elements (pos + color) = 12
                y: 1,
                z: 1,
                t: 1,
                format: ElementFormat::F32x4,
            },
            192, // 12 * 16
            MemoryTier::ShortTerm,
            Some("quad-verts"),
        )
        .unwrap();

    // Triangle 1: top-left, bottom-left, bottom-right
    write_vertex(&kernel, verts, 0, (-1.0, -1.0, 0.0, 1.0), (1.0, 0.0, 0.0, 1.0)); // red
    write_vertex(&kernel, verts, 1, (-1.0, 1.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0));  // green
    write_vertex(&kernel, verts, 2, (1.0, 1.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0));   // blue

    // Triangle 2: top-left, bottom-right, top-right
    write_vertex(&kernel, verts, 3, (-1.0, -1.0, 0.0, 1.0), (1.0, 0.0, 0.0, 1.0)); // red
    write_vertex(&kernel, verts, 4, (1.0, 1.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0));   // blue
    write_vertex(&kernel, verts, 5, (1.0, -1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0));  // yellow

    let transform = Mat4::identity();
    rasterize(
        &kernel,
        verts,
        transform,
        fb,
        Some([0x27, 0x29, 0x2A, 0xFF]),
    )
    .unwrap();

    let surface = RegionSurface::open(&kernel, fb).unwrap();

    // Sample 4 corners — they should all be inside the quad (colored, not clear)
    let tl = surface.read_element(0, 0, 0, 0).unwrap();
    let tr = surface.read_element(7, 0, 0, 0).unwrap();
    let bl = surface.read_element(0, 7, 0, 0).unwrap();
    let br = surface.read_element(7, 7, 0, 0).unwrap();

    // All should be non-black (something rendered)
    for (name, px) in &[("tl", &tl), ("tr", &tr), ("bl", &bl), ("br", &br)] {
        let is_colored = px[0] > 0 || px[1] > 0 || px[2] > 0;
        assert!(
            is_colored,
            "{} should be colored, got {:?}",
            name, px
        );
    }

    // Center should be somewhere between the vertex colors
    let center = surface.read_element(4, 4, 0, 0).unwrap();
    let is_center_colored = center[0] > 0 || center[1] > 0 || center[2] > 0;
    assert!(is_center_colored, "Center should be colored, got {:?}", center);
}

#[test]
fn blend_then_composite() {
    let kernel = MockKernel::new();

    // Create a display region
    let display = kernel
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
            Some("display"),
        )
        .unwrap();

    // Create an overlay region (semi-transparent)
    let overlay = kernel
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
            Some("overlay"),
        )
        .unwrap();

    let display_surface = RegionSurface::open(&kernel, display).unwrap();
    let overlay_surface = RegionSurface::open(&kernel, overlay).unwrap();

    // Fill display with dark background
    for y in 0..4 {
        for x in 0..4 {
            display_surface
                .write_pixel(x, y, 0, 0, 0x27, 0x29, 0x2A, 0xFF)
                .unwrap();
        }
    }

    // Fill overlay with semi-transparent red
    for y in 0..4 {
        for x in 0..4 {
            overlay_surface
                .write_pixel(x, y, 0, 0, 255, 0, 0, 64)
                .unwrap();
        }
    }

    // Blend overlay onto display
    render::blend::blend(&kernel, overlay, display).unwrap();

    // After blending, display should be tinted red
    let result = display_surface.read_element(2, 2, 0, 0).unwrap();
    // Red channel should be higher than original dark gray
    assert!(result[0] > 0x27, "Red channel should be boosted from blending");
    // Green should be near original (slightly blended)
    assert!(result[1] <= 0x29 + 5, "Green channel should be near original");
}
