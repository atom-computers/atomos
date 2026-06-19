-- Gluon Standard Library: Collections
-- Functional operations on spatial regions: map, reduce, filter, zip, scan, sort.

-- Map: apply a transformation to every element of a region
process region_map:
    reads  src: region[dims] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[dims] of F32x4 @ ShortTerm @ ReadWrite
    private transform: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ LongTerm
    -- transform.c0 = scale factor, transform.c1 = offset
    -- dst = src * scale + offset

    when src or transform changes:
        let scale = transform[x: 0, y: 0, z: 0, t: 0].c0;
        let offset = transform[x: 0, y: 0, z: 0, t: 0].c1;
        for each (i, j, k, t) in dst[x: *, y: *, z: *, t: *]:
            let v = src[x: i, y: j, z: k, t: t].c0;
            dst[x: i, y: j, z: k, t: t] := [v * scale + offset, 0, 0, 0];
        end

    ensures:
        dst.dimensions == src.dimensions;
end

-- Reduce: sum all elements along axis 0
process region_reduce_sum:
    reads  src: region[x: N px, y: M px, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when src changes:
        let mut total = 0.0;
        for each (i, j) in src[x: *, y: *, z: 0, t: 0]:
            total := total + src[x: i, y: j, z: 0, t: 0].c0;
        end
        dst[x: 0, y: 0, z: 0, t: 0] := [total, 0, 0, 0];
end

-- Reduce maximum: find the maximum value in a region
process region_reduce_max:
    reads  src: region[x: N px, y: M px, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when src changes:
        let mut max_val = src[x: 0, y: 0, z: 0, t: 0].c0;
        for each (i, j) in src[x: *, y: *, z: 0, t: 0]:
            let v = src[x: i, y: j, z: 0, t: 0].c0;
            max_val := if v > max_val then v else max_val;
        end
        dst[x: 0, y: 0, z: 0, t: 0] := [max_val, 0, 0, 0];
end

-- Argmax: find the index of the maximum value (useful for classification)
process region_argmax:
    reads  src: region[x: N class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[x: B batch, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when src changes:
        for each b in 0..B:
            let mut max_val = src[x: 0, y: 0, z: 0, t: b].c0;
            let mut max_idx = 0u32;
            for each i in 1..N:
                let v = src[x: i, y: 0, z: 0, t: b].c0;
                if v > max_val:
                    max_val := v;
                    max_idx := i;
                end
            end
            dst[x: b, y: 0, z: 0, t: 0] := [max_idx as f32, max_val, 0, 0];
        end
end

-- Filter: select elements where predicate is true (produces a smaller region)
process region_filter:
    reads  src: region[x: N, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadOnly
    reads  threshold: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[x: N, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadWrite
    private count: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when src or threshold changes:
        let thresh = threshold[x: 0, y: 0, z: 0, t: 0].c0;
        let mut n = 0u32;
        for each i in 0..N:
            if src[x: i, y: 0, z: 0, t: 0].c0 > thresh:
                dst[x: n, y: 0, z: 0, t: 0] := src[x: i, y: 0, z: 0, t: 0];
                n := n + 1;
            end
        end
        -- Zero out remaining slots
        for each i in n..N:
            dst[x: i, y: 0, z: 0, t: 0] := [0, 0, 0, 0];
        end
        count[x: 0, y: 0, z: 0, t: 0] := [n as f32, 0, 0, 0];
end

-- Zip: combine two regions element-wise using a binary operation
process region_zip_add:
    reads  a: region[dims] of F32x4 @ ShortTerm @ ReadOnly
    reads  b: region[dims] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[dims] of F32x4 @ ShortTerm @ ReadWrite

    when a or b changes:
        for each (i, j, k, t) in dst[x: *, y: *, z: *, t: *]:
            let av = a[x: i, y: j, z: k, t: t].c0;
            let bv = b[x: i, y: j, z: k, t: t].c0;
            dst[x: i, y: j, z: k, t: t] := [av + bv, 0, 0, 0];
        end

    ensures:
        dst.dimensions == a.dimensions;
end

-- Prefix scan (cumulative sum) along the x-axis
process region_scan:
    reads  src: region[x: N, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes dst: region[x: N, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm @ ReadWrite

    when src changes:
        let mut accum = 0.0;
        for each i in 0..N:
            accum := accum + src[x: i, y: 0, z: 0, t: 0].c0;
            dst[x: i, y: 0, z: 0, t: 0] := [accum, 0, 0, 0];
        end
end

-- Gather: select elements from a region by index
-- indices region holds the indices to read from source
process region_gather:
    reads  source:  region[x: N, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm @ ReadOnly
    reads  indices: region[x: M, y: 1, z: 1, t: B batch] of U8x4 @ ShortTerm @ ReadOnly
    writes result:  region[x: M, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when source or indices changes:
        for each b in 0..B:
            for each i in 0..M:
                let idx = indices[x: i, y: 0, z: 0, t: b].c0 as u32;
                if idx < N:
                    result[x: i, y: 0, z: 0, t: b] := [source[x: idx, y: 0, z: 0, t: b].c0, 0, 0, 0];
                else:
                    result[x: i, y: 0, z: 0, t: b] := [0, 0, 0, 0];
                end
            end
        end

    ensures:
        result.dimensions == indices.dimensions;
end