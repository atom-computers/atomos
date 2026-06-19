-- Gluon Standard Library: Matrix Operations
-- 4x4 matrix construction and manipulation for 3D graphics and transforms.
-- Matrices are stored as Spatial regions of F32x4 where each element is a
-- column vector (x, y, z, w).

region identity_cache: region[x: 4, y: 4, z: 1, t: 1] of F32x4 @ LongTerm;

process make_identity:
    writes identity_cache

    when identity_cache is empty:
        identity_cache[x: 0, y: 0, z: 0, t: 0] := [1.0, 0.0, 0.0, 0.0];
        identity_cache[x: 1, y: 0, z: 0, t: 0] := [0.0, 1.0, 0.0, 0.0];
        identity_cache[x: 2, y: 0, z: 0, t: 0] := [0.0, 0.0, 1.0, 0.0];
        identity_cache[x: 0, y: 3, z: 0, t: 0] := [0.0, 0.0, 0.0, 1.0];
    end

-- Matrix multiply: C = A * B
-- A: [x: 4, y: 1, z: 1, t: 1] of F32x4 (4 column vectors)
-- B: [x: 4, y: 1, z: 1, t: 1] of F32x4 (4 column vectors)
-- C: [x: 4, y: 1, z: 1, t: 1] of F32x4 (result)
process mat4_mul:
    reads a: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads b: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes c: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when a or b changes:
        -- Column j of result = A * column j of B
        for each j in 0..4:
            let b0 = b[x: 0, y: 0, z: 0, t: 0].c0;
            let b1 = b[x: 1, y: 0, z: 0, t: 0].c0;
            let b2 = b[x: 2, y: 0, z: 0, t: 0].c0;
            let b3 = b[x: 3, y: 0, z: 0, t: 0].c0;

            let a00 = a[x: 0, y: 0, z: 0, t: j].c0;
            let a10 = a[x: 0, y: 0, z: 0, t: j].c1;
            let a20 = a[x: 0, y: 0, z: 0, t: j].c2;
            let a30 = a[x: 0, y: 0, z: 0, t: j].c3;

            let cx = a00 * b0 + a[1].c0 * b1 + a[2].c0 * b2 + a[3].c0 * b3;
            let cy = a[0].c1 * b0 + a[1].c1 * b1 + a[2].c1 * b2 + a[3].c1 * b3;
            let cz = a[0].c2 * b0 + a[1].c2 * b1 + a[2].c2 * b2 + a[3].c2 * b3;
            let cw = a[0].c3 * b0 + a[1].c3 * b1 + a[2].c3 * b2 + a[3].c3 * b3;

            c[x: j, y: 0, z: 0, t: 0] := [cx, cy, cz, cw];
        end
end

process mat4_translate:
    reads tx: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads ty: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads tz: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes result: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when tx or ty or tz changes:
        let x = tx[x: 0, y: 0, z: 0, t: 0].c0;
        let y = ty[x: 0, y: 0, z: 0, t: 0].c0;
        let z = tz[x: 0, y: 0, z: 0, t: 0].c0;

        result[x: 0, y: 0, z: 0, t: 0] := [1.0, 0.0, 0.0, 0.0];
        result[x: 1, y: 0, z: 0, t: 0] := [0.0, 1.0, 0.0, 0.0];
        result[x: 2, y: 0, z: 0, t: 0] := [0.0, 0.0, 1.0, 0.0];
        result[x: 3, y: 0, z: 0, t: 0] := [x, y, z, 1.0];
    end

process mat4_scale:
    reads sx: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads sy: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads sz: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes result: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when sx or sy or sz changes:
        let x = sx[x: 0, y: 0, z: 0, t: 0].c0;
        let y = sy[x: 0, y: 0, z: 0, t: 0].c0;
        let z = sz[x: 0, y: 0, z: 0, t: 0].c0;

        result[x: 0, y: 0, z: 0, t: 0] := [x, 0.0, 0.0, 0.0];
        result[x: 1, y: 0, z: 0, t: 0] := [0.0, y, 0.0, 0.0];
        result[x: 2, y: 0, z: 0, t: 0] := [0.0, 0.0, z, 0.0];
        result[x: 3, y: 0, z: 0, t: 0] := [0.0, 0.0, 0.0, 1.0];
    end

process mat4_perspective:
    reads fov: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads aspect: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads near: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads far: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes result: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when fov or aspect or near or far changes:
        let f = 1.0 / tan(fov[x: 0, y: 0, z: 0, t: 0].c0 * 0.5);
        let a = aspect[x: 0, y: 0, z: 0, t: 0].c0;
        let n = near[x: 0, y: 0, z: 0, t: 0].c0;
        let fr = far[x: 0, y: 0, z: 0, t: 0].c0;

        result[x: 0, y: 0, z: 0, t: 0] := [f / a, 0.0, 0.0, 0.0];
        result[x: 1, y: 0, z: 0, t: 0] := [0.0, f, 0.0, 0.0];
        result[x: 2, y: 0, z: 0, t: 0] := [0.0, 0.0, -(fr + n) / (fr - n), -1.0];
        result[x: 3, y: 0, z: 0, t: 0] := [0.0, 0.0, -2.0 * fr * n / (fr - n), 0.0];
    end

process mat4_orthographic:
    reads params: region[x: 6, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    -- params: [left, right, bottom, top, near, far]
    writes result: region[x: 4, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when params changes:
        let l = params[x: 0, y: 0, z: 0, t: 0].c0;
        let r = params[x: 1, y: 0, z: 0, t: 0].c0;
        let b = params[x: 2, y: 0, z: 0, t: 0].c0;
        let t = params[x: 3, y: 0, z: 0, t: 0].c0;
        let n = params[x: 4, y: 0, z: 0, t: 0].c0;
        let f = params[x: 5, y: 0, z: 0, t: 0].c0;

        result[x: 0, y: 0, z: 0, t: 0] := [2.0 / (r - l), 0.0, 0.0, 0.0];
        result[x: 1, y: 0, z: 0, t: 0] := [0.0, 2.0 / (t - b), 0.0, 0.0];
        result[x: 2, y: 0, z: 0, t: 0] := [0.0, 0.0, -2.0 / (f - n), 0.0];
        result[x: 3, y: 0, z: 0, t: 0] := [-(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n), 1.0];
    end