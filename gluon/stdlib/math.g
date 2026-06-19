-- Gluon Standard Library: Math
-- Pure math functions. These operate on scalars, not regions.

process sin_table:
    -- Precomputed sin/cos lookup for angles 0..360 in 0.25° steps
    private table: region[x: 1441, y: 1, z: 1, t: 1] of F32x4 @ LongTerm

    when table is empty:
        for each i in 0..1441:
            let angle = i as f32 * 0.25 * 3.14159265 / 180.0;
            table[x: i, y: 0, z: 0, t: 0] := [sin(angle), cos(angle), tan(angle), angle];
        end
end

process scalar_math:
    -- Provides math operations on scalar values extracted from regions.
    -- These are implemented as lookup + interpolation rather than
    -- hardware-specific instructions, ensuring portability.

    reads input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes output: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    private lut: region[x: 1441, y: 1, z: 1, t: 1] of F32x4 @ LongTerm

    -- sin(x): lookup table with linear interpolation
    -- input.c0 = angle in radians
    -- output.c0 = sin(angle)
    when input changes:
        let angle = input[x: 0, y: 0, z: 0, t: 0].c0;
        let angle_norm = angle * 180.0 / 3.14159265;
        let index_f = angle_norm / 0.25;
        let index_lo = floor(index_f) as u32;
        let index_hi = index_lo + 1;
        let frac = index_f - floor(index_f);
        let v_lo = lut[x: index_lo, y: 0, z: 0, t: 0].c0;
        let v_hi = lut[x: index_hi, y: 0, z: 0, t: 0].c0;
        output[x: 0, y: 0, z: 0, t: 0] := [v_lo + (v_hi - v_lo) * frac, 0, 0, 0];
    end

region abs_input:  region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm;
region abs_output: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm;

process abs_scalar:
    reads abs_input;
    writes abs_output;

    when abs_input changes:
        let v = abs_input[x: 0, y: 0, z: 0, t: 0].c0;
        let result = if v < 0.0 then -v else v;
        abs_output[x: 0, y: 0, z: 0, t: 0] := [result, 0, 0, 0];
    end

process min_scalar:
    reads a_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads b_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes min_output: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when a_input or b_input changes:
        let a = a_input[x: 0, y: 0, z: 0, t: 0].c0;
        let b = b_input[x: 0, y: 0, z: 0, t: 0].c0;
        min_output[x: 0, y: 0, z: 0, t: 0] := [if a < b then a else b, 0, 0, 0];
    end

process max_scalar:
    reads a_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads b_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes max_output: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when a_input or b_input changes:
        let a = a_input[x: 0, y: 0, z: 0, t: 0].c0;
        let b = b_input[x: 0, y: 0, z: 0, t: 0].c0;
        max_output[x: 0, y: 0, z: 0, t: 0] := [if a > b then a else b, 0, 0, 0];
    end

process clamp_scalar:
    reads x_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads lo_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    reads hi_input: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes clamp_output: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when x_input or lo_input or hi_input changes:
        let x = x_input[x: 0, y: 0, z: 0, t: 0].c0;
        let lo = lo_input[x: 0, y: 0, z: 0, t: 0].c0;
        let hi = hi_input[x: 0, y: 0, z: 0, t: 0].c0;
        let clamped = if x < lo then lo else if x > hi then hi else x;
        clamp_output[x: 0, y: 0, z: 0, t: 0] := [clamped, 0, 0, 0];
    end

-- Region-wide operations: apply math across all elements
process region_abs:
    reads src: region[dims] of F32x4 @ ShortTerm
    writes dst: region[dims] of F32x4 @ ShortTerm

    when src changes:
        for each (i, j, k, t) in dst[x: *, y: *, z: *, t: *]:
            let v = src[x: i, y: j, z: k, t: t].c0;
            dst[x: i, y: j, z: k, t: t] := [if v < 0.0 then -v else v, 0, 0, 0];
        end

    ensures:
        dst.c0 >= 0.0 forall elements;
        dst.dimensions == src.dimensions;
end

-- Sum all elements along axis 0 of an F32x4 region
process reduce_sum:
    reads src: region[x: N px, y: M px, z: 1, t: 1] of F32x4 @ ShortTerm
    writes dst: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    private accum: f32 = 0.0

    when src changes:
        accum := 0.0;
        for each (i, j) in src[x: *, y: *, z: 0, t: 0]:
            accum := accum + src[x: i, y: j, z: 0, t: 0].c0;
        end
        dst[x: 0, y: 0, z: 0, t: 0] := [accum, 0, 0, 0];
    end