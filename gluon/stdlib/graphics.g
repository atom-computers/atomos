-- Gluon Standard Library: Graphics
-- Rendering primitives built on matrix math and spatial regions.
-- All operations use the kernel's region read/write API.

process clear_region:
    reads target: region[dims] of U8x4 @ ReadWrite
    private color: region[x: 1, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm

    when target changes:
        let c = color[x: 0, y: 0, z: 0, t: 0];
        for each (i, j, k, t) in target[x: *, y: *, z: *, t: current]:
            target[x: i, y: j, z: k, t: t] := c;
        end
end

process blend_alpha:
    -- Alpha compositing: dst = src * src.a + dst * (1 - src.a)
    -- src_over_dst mode. Both regions must have matching dimensions and U8x4 format.
    reads src: region[x: W px, y: H px, z: 1, t: 1] of U8x4 @ ReadOnly
    reads dst: region[x: W px, y: H px, z: 1, t: 1] of U8x4 @ ReadWrite

    when src changes:
        for each (i, j) in dst[x: *, y: *, z: 0, t: 0]:
            let s = src[x: i, y: j, z: 0, t: 0];
            let d = dst[x: i, y: j, z: 0, t: 0];
            let sa = s.a as f32 / 255.0;
            let da = 1.0 - sa;
            let r = (s.r as f32 * sa + d.r as f32 * da) as u8;
            let g = (s.g as f32 * sa + d.g as f32 * da) as u8;
            let b = (s.b as f32 * sa + d.b as f32 * da) as u8;
            let a = max(s.a, d.a);
            dst[x: i, y: j, z: 0, t: 0] := [r, g, b, a];
        end

    ensures:
        dst.a >= src.a forall pixels;
        dst.dimensions == src.dimensions;
end

process blend_with_opacity:
    -- Blend with explicit opacity factor
    reads src: region[x: W px, y: H px, z: 1, t: 1] of U8x4 @ ReadOnly
    reads dst: region[x: W px, y: H px, z: 1, t: 1] of U8x4 @ ReadWrite
    private opacity: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when src changes:
        let a = opacity[x: 0, y: 0, z: 0, t: 0].c0;
        let clamped_a = if a < 0.0 then 0.0 else if a > 1.0 then 1.0 else a;
        for each (i, j) in dst[x: *, y: *, z: 0, t: 0]:
            let s = src[x: i, y: j, z: 0, t: 0];
            let d = dst[x: i, y: j, z: 0, t: 0];
            let sa = s.a as f32 / 255.0 * clamped_a;
            let da = 1.0 - sa;
            let r = (s.r as f32 * sa + d.r as f32 * da) as u8;
            let g = (s.g as f32 * sa + d.g as f32 * da) as u8;
            let b = (s.b as f32 * sa + d.b as f32 * da) as u8;
            dst[x: i, y: j, z: 0, t: 0] := [r, g, b, 255];
        end

    ensures:
        dst.a == 255 forall pixels;
end

process double_buffer_swap:
    -- Swap current and next frames in a double-buffered region
    reads fb: region[x: W px, y: H px, z: 1, t: 2frames] of U8x4 @ ReadWrite

    every 16ms:
        swap fb[t: current] with fb[t: next];

    ensures:
        not (fb[t: 0].being_written and fb[t: 0].being_scanned);
end