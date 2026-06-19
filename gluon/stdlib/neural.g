-- Gluon Standard Library: Neural Network Operations
-- Layer operations implemented as reactive processes on F32x4 spatial regions.
-- Each process declares its inputs, outputs, and weight regions.

-- 2D Convolution: convolve a kernel over a spatial input
-- Output dimensions: (W - K_w + 2*P) / S + 1 x (H - K_h + 2*P) / S + 1
process conv2d:
    reads  input:  region neural [x: W px, y: H px, z: C_in chan, t: B batch] of F32x4 @ ShortTerm
    private kernel: region neural [x: K px, y: K px, z: C_in chan, t: C_out chan] of F32x4 @ LongTerm
    private bias:   region neural [x: 1, y: 1, z: 1, t: C_out chan] of F32x4 @ LongTerm
    writes output:  region neural [x: (W-K+1) px, y: (H-K+1) px, z: C_out chan, t: B batch] of F32x4 @ ShortTerm

    when input changes:
        convolve kernel over input into output;
        -- convolve handles: for each (ox, oy, oc, b):
        --   output[ox, oy, oc, b] = sum over (kx, ky, ic): input[ox+kx, oy+ky, ic, b] * kernel[kx, ky, ic, oc]
        --   then add bias[oc]

    ensures:
        output.dimensions == [x: (W-K+1) px, y: (H-K+1) px, z: C_out chan, t: B batch];
        output.is_finite forall elements;
end

-- 2D Max Pooling with stride
process maxpool2d:
    reads  input:  region neural [x: W px, y: H px, z: C chan, t: B batch] of F32x4 @ ShortTerm
    writes output:  region neural [x: W/2 px, y: H/2 px, z: C chan, t: B batch] of F32x4 @ ShortTerm

    when input changes:
        for each (ox, oy, c, b) in output[x: *, y: *, z: *, t: *]:
            let mut max_val = input[x: ox*2, y: oy*2, z: c, t: b].c0;
            for each (dx, dy) in [(0,0), (1,0), (0,1), (1,1)]:
                let v = input[x: ox*2+dx, y: oy*2+dy, z: c, t: b].c0;
                max_val := if v > max_val then v else max_val;
            end
            output[x: ox, y: oy, z: c, t: b] := [max_val, 0, 0, 0];
        end

    ensures:
        output.dimensions == [x: W/2 px, y: H/2 px, z: C chan, t: B batch];
        output.c0 >= 0.0 forall elements;
end

-- ReLU activation: max(0, x)
process relu:
    reads  input: region neural [dims] of F32x4 @ ShortTerm
    writes output: region neural [dims] of F32x4 @ ShortTerm

    when input changes:
        for each idx in output[x: *, y: *, z: *, t: *]:
            let v = input[idx].c0;
            output[idx] := [if v > 0.0 then v else 0.0, 0, 0, 0];
        end

    ensures:
        output.c0 >= 0.0 forall elements;
        output.dimensions == input.dimensions;
end

-- Sigmoid activation: 1 / (1 + exp(-x))
process sigmoid:
    reads  input: region neural [dims] of F32x4 @ ShortTerm
    writes output: region neural [dims] of F32x4 @ ShortTerm

    when input changes:
        for each idx in output[x: *, y: *, z: *, t: *]:
            let v = input[idx].c0;
            let s = 1.0 / (1.0 + exp(-v));
            output[idx] := [s, 0, 0, 0];
        end

    ensures:
        output.c0 >= 0.0 and output.c0 <= 1.0 forall elements;
        output.dimensions == input.dimensions;
end

-- Softmax: exp(x_i) / sum(exp(x_j)) along the x-axis
process softmax:
    reads  input: region neural [x: N class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    writes output: region neural [x: N class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when input changes:
        for each b in 0..B:
            -- Find max for numerical stability
            let mut max_val = input[x: 0, y: 0, z: 0, t: b].c0;
            for each i in 1..N:
                let v = input[x: i, y: 0, z: 0, t: b].c0;
                max_val := if v > max_val then v else max_val;
            end

            -- Compute sum of exp(x - max)
            let mut sum_exp = 0.0;
            for each i in 0..N:
                let v = input[x: i, y: 0, z: 0, t: b].c0;
                sum_exp := sum_exp + exp(v - max_val);
            end

            -- Normalize
            for each i in 0..N:
                let v = input[x: i, y: 0, z: 0, t: b].c0;
                output[x: i, y: 0, z: 0, t: b] := [exp(v - max_val) / sum_exp, 0, 0, 0];
            end
        end

    ensures:
        sum(output.c0) ≈ 1.0 within 1e-6 forall batch;
        output.c0 >= 0.0 forall elements;
end

-- Matrix multiplication: C = A * B
-- A: [x: M, y: 1, z: 1, t: B] of F32x4
-- B: [x: K, y: 1, z: 1, t: B] of F32x4  (actually [x: N, y: K, z: 1, t: 1])
-- C: [x: M, y: 1, z: 1, t: B] of F32x4
process linear:
    reads  x: region neural [x: M feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private w: region neural [x: M feat, y: N feat, z: 1, t: 1] of F32x4 @ LongTerm
    private b: region neural [x: N feat, y: 1, z: 1, t: 1] of F32x4 @ LongTerm
    writes y: region neural [x: N feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when x changes:
        matmul x through w into y;
        broadcast_add b to y;

    ensures:
        y.dimensions == [x: N feat, y: 1, z: 1, t: B batch];
        y.is_finite forall elements;
end

-- Batch normalization: normalize each feature across the batch
process batch_norm:
    reads  input:     region neural [x: N feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private gamma: region neural [x: N feat, y: 1, z: 1, t: 1] of F32x4 @ LongTerm
    private beta:  region neural [x: N feat, y: 1, z: 1, t: 1] of F32x4 @ LongTerm
    writes output:    region neural [x: N feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when input changes:
        -- Compute mean and variance per feature
        for each n in 0..N:
            let mut mean = 0.0;
            for each b in 0..B:
                mean := mean + input[x: n, y: 0, z: 0, t: b].c0;
            end
            mean := mean / B as f32;

            let mut var = 0.0;
            for each b in 0..B:
                let v = input[x: n, y: 0, z: 0, t: b].c0;
                var := var + (v - mean) * (v - mean);
            end
            var := var / B as f32;

            let g = gamma[x: n, y: 0, z: 0, t: 0].c0;
            let b = beta[x: n, y: 0, z: 0, t: 0].c0;
            let std_inv = 1.0 / sqrt(var + 1e-5);

            for each b in 0..B:
                let v = input[x: n, y: 0, z: 0, t: b].c0;
                output[x: n, y: 0, z: 0, t: b] := [g * (v - mean) * std_inv + b, 0, 0, 0];
            end
        end

    ensures:
        output.dimensions == input.dimensions;
        output.is_finite forall elements;
end