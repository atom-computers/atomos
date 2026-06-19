-- Gluon Standard Library: Storage
-- Compression, serialization, and memory tier management.
-- These processes operate on Raw regions (byte buffers) and manage data persistence.

-- Compress a Raw region using LZ4-style compression
-- Output is always smaller than or equal to input
process compress:
    reads  input:  region[len: N byte] of Raw @ LongTerm @ ReadOnly
    writes output: region[len: M byte] of Raw @ LongTerm @ ReadWrite
    private out_pos: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when input changes:
        -- Simple run-length encoding for demonstration
        -- Production implementation would use LZ4 or similar
        let mut in_idx = 0u32;
        let mut out_idx = 0u32;
        while in_idx < N:
            let current = input[in_idx];
            let mut run_len = 1u32;
            while in_idx + run_len < N and input[in_idx + run_len] == current and run_len < 255:
                run_len := run_len + 1;
            end
            output[out_idx] := run_len as u8;
            output[out_idx + 1] := current;
            in_idx := in_idx + run_len;
            out_idx := out_idx + 2;
        end
        out_pos[x: 0, y: 0, z: 0, t: 0] := [out_idx as f32, 0, 0, 0];

    ensures:
        out_pos[x: 0, y: 0, z: 0, t: 0].c0 <= N as f32;
end

-- Decompress a previously compressed region
process decompress:
    reads  input:  region[len: M byte] of Raw @ LongTerm @ ReadOnly
    writes output: region[len: N byte] of Raw @ LongTerm @ ReadWrite
    private expected_len: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when input changes:
        let mut in_idx = 0u32;
        let mut out_idx = 0u32;
        while in_idx < M and out_idx < N:
            let run_len = input[in_idx] as u32;
            let value = input[in_idx + 1];
            for each i in 0..run_len:
                if out_idx + i < N:
                    output[out_idx + i] := value;
                end
            end
            in_idx := in_idx + 2;
            out_idx := out_idx + run_len;
        end
end

-- Serialize an F32x4 spatial region into a contiguous Raw byte buffer
-- Format: [x_len: u32, y_len: u32, z_len: u32, t_len: u32, element_count: u32, data...]
process serialize_f32x4:
    reads  input:  region[x: X, y: Y, z: Z, t: T] of F32x4 @ ShortTerm @ ReadOnly
    writes output: region[len: header_size + X*Y*Z*T*16 byte] of Raw @ LongTerm @ ReadWrite

    when input changes:
        -- Write header: dimensions
        let offset = 0;
        output[0..4] := X.to_le_bytes();
        output[4..8] := Y.to_le_bytes();
        output[8..12] := Z.to_le_bytes();
        output[12..16] := T.to_le_bytes();

        -- Write element data
        for each (i, j, k, t) in input[x: *, y: *, z: *, t: *]:
            let elem = input[x: i, y: j, z: k, t: t];
            let base = 16 + ((i * Y * Z * T + j * Z * T + k * T + t) * 16);
            output[base..base+4] := elem.c0.to_le_bytes();
            output[base+4..base+8] := elem.c1.to_le_bytes();
            output[base+8..base+12] := elem.c2.to_le_bytes();
            output[base+12..base+16] := elem.c3.to_le_bytes();
        end
end

-- Deserialize a Raw byte buffer back into an F32x4 spatial region
process deserialize_f32x4:
    reads  input:  region[len: N byte] of Raw @ LongTerm @ ReadOnly
    writes output: region[x: X, y: Y, z: Z, t: T] of F32x4 @ ShortTerm @ ReadWrite

    when input changes:
        -- Read header
        let x_len = u32_from_le(input[0..4]);
        let y_len = u32_from_le(input[4..8]);
        let z_len = u32_from_le(input[8..12]);
        let t_len = u32_from_le(input[12..16]);

        -- Read element data
        for each (i, j, k, t) in output[x: *, y: *, z: *, t: *]:
            let base = 16 + ((i * y_len * z_len * t_len + j * z_len * t_len + k * t_len + t) * 16);
            let c0 = f32_from_le(input[base..base+4]);
            let c1 = f32_from_le(input[base+4..base+8]);
            let c2 = f32_from_le(input[base+8..base+12]);
            let c3 = f32_from_le(input[base+12..base+16]);
            output[x: i, y: j, z: k, t: t] := [c0, c1, c2, c3];
        end
end

-- Persist a region: ensure it's in LongTerm storage and flush to durable media
process persist:
    reads  target: region[dims] of format @ ReadWrite

    every 1s:
        migrate target from ShortTerm to LongTerm;
end

-- Migrate a region between memory tiers
process migrate_region:
    reads  target: region[dims] of format @ ReadWrite
    private from_tier: region[x: 1, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm
    private to_tier:   region[x: 1, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm

    when from_tier or to_tier changes:
        let src = from_tier[x: 0, y: 0, z: 0, t: 0].c0;
        let dst = to_tier[x: 0, y: 0, z: 0, t: 0].c0;
        if src == 0 and dst == 1:
            migrate target from ShortTerm to LongTerm;
        else if src == 1 and dst == 0:
            migrate target from LongTerm to ShortTerm;
        end
end