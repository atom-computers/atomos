-- Gluon Standard Library: Signal Processing
-- FFT, filtering, downsampling, and normalization on spatial F32x4 regions.

-- Fast Fourier Transform: compute DFT of a 1D signal
-- Input: spatial region of size N (must be power of 2)
-- Output: complex frequency components [real, imag, magnitude, phase]
process fft_1d:
    reads  input:  region neural [x: N sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    writes output:  region neural [x: N sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private bit_rev: region neural [x: N sample, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm

    when input changes:
        -- Bit-reversal permutation
        for each i in 0..N:
            let rev = bit_reverse(i, log2(N));
            bit_rev[x: i, y: 0, z: 0, t: 0] := [rev as u8, 0, 0, 0];
        end

        -- Copy input to output in bit-reversed order
        for each b in 0..B:
            for each i in 0..N:
                let rev = bit_rev[x: i, y: 0, z: 0, t: 0].c0 as u32;
                output[x: rev, y: 0, z: 0, t: b] := input[x: i, y: 0, z: 0, t: b];
            end

            -- Butterfly stages
            let mut stage_size = 2;
            while stage_size <= N:
                let half = stage_size / 2;
                let angle_step = -2.0 * 3.14159265 / stage_size as f32;

                for each k in 0..half:
                    let angle = angle_step * k as f32;
                    let wr = cos(angle);
                    let wi = sin(angle);

                    for each m in 0..(N / stage_size):
                        let even_idx = m * stage_size + k;
                        let odd_idx = even_idx + half;

                        let er = output[x: even_idx, y: 0, z: 0, t: b].c0;
                        let ei = output[x: even_idx, y: 0, z: 0, t: b].c1;
                        let orr = output[x: odd_idx, y: 0, z: 0, t: b].c0;
                        let oi = output[x: odd_idx, y: 0, z: 0, t: b].c1;

                        let tr = wr * orr - wi * oi;
                        let ti = wr * oi + wi * orr;

                        output[x: even_idx, y: 0, z: 0, t: b] := [er + tr, ei + ti, 0, 0];
                        output[x: odd_idx, y: 0, z: 0, t: b] := [er - tr, ei - ti, 0, 0];
                    end
                end

                stage_size := stage_size * 2;
            end

            -- Compute magnitude and phase
            for each i in 0..N:
                let r = output[x: i, y: 0, z: 0, t: b].c0;
                let im = output[x: i, y: 0, z: 0, t: b].c1;
                let mag = sqrt(r * r + im * im);
                let phase = atan2(im, r);
                output[x: i, y: 0, z: 0, t: b] := [r, im, mag, phase];
            end
        end

    ensures:
        output.dimensions == input.dimensions;
end

-- Low-pass filter: zero out frequency components above cutoff
process lowpass_filter:
    reads  spectrum: region neural [x: N sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private cutoff: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes filtered: region neural [x: N sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when spectrum changes:
        let cutoff_idx = cutoff[x: 0, y: 0, z: 0, t: 0].c0 as u32;
        for each b in 0..B:
            for each i in 0..N:
                if i < cutoff_idx or i > N - cutoff_idx:
                    filtered[x: i, y: 0, z: 0, t: b] := spectrum[x: i, y: 0, z: 0, t: b];
                else:
                    filtered[x: i, y: 0, z: 0, t: b] := [0, 0, 0, 0];
                end
            end
        end
end

-- Downsample: take every Nth sample
process downsample:
    reads  input:   region neural [x: N sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private stride: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes output:  region neural [x: N/S sample, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when input changes:
        let s = stride[x: 0, y: 0, z: 0, t: 0].c0 as u32;
        for each b in 0..B:
            for each i in 0..(N / s):
                output[x: i, y: 0, z: 0, t: b] := input[x: i * s, y: 0, z: 0, t: b];
            end
        end

    ensures:
        output.dimensions == [x: N/S sample, y: 1, z: 1, t: B batch];
end

-- Normalize: scale signal to [-1, 1] range
process normalize:
    reads  input:  region neural [x: N sample, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    writes output: region neural [x: N sample, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when input changes:
        let mut max_abs = 0.0;
        for each i in 0..N:
            let v = input[x: i, y: 0, z: 0, t: 0].c0;
            let av = if v < 0.0 then -v else v;
            max_abs := if av > max_abs then av else max_abs;
        end
        if max_abs > 0.0:
            for each i in 0..N:
                let v = input[x: i, y: 0, z: 0, t: 0].c0;
                output[x: i, y: 0, z: 0, t: 0] := [v / max_abs, 0, 0, 0];
            end
        end

    ensures:
        output.c0 >= -1.0 and output.c0 <= 1.0 forall elements;
end