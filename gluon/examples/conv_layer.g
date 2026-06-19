-- Convolutional Layer: 2D convolution + ReLU + max pooling
-- Demonstrates: F32x4 neural context, convolve, pool, relu, dimensional verification

region sensor_input: region neural [x: 64channel, y: 64channel, z: 1depth, t: 1sample] of F32x4
    @ ShortTerm @ ReadOnly;
region conv_kernel:  region neural [x: 3channel, y: 3channel, z: 1depth, t: 1] of F32x4
    @ LongTerm @ ReadOnly;
region activation:  region neural [x: 62channel, y: 62channel, z: 1depth, t: 1sample] of F32x4
    @ ShortTerm @ ReadWrite;
region pooled:      region neural [x: 31channel, y: 31channel, z: 1depth, t: 1sample] of F32x4
    @ ShortTerm @ ReadWrite;

process conv_layer:
    reads  sensor_input, conv_kernel;
    writes activation, pooled;

    when sensor_input changes:
        -- Convolution: 64×64 input, 3×3 kernel → 62×62 output
        convolve conv_kernel over sensor_input into activation;
        relu activation in place;

        -- Max pooling with stride 2: 62×62 → 31×31
        pool activation by 2 into pooled;

    requires:
        sensor_input.dimensions == [x: 64channel, y: 64channel, z: 1depth, t: 1sample];
        conv_kernel.dimensions == [x: 3channel, y: 3channel, z: 1depth, t: 1];

    ensures:
        activation.dimensions == [x: 62channel, y: 62channel, z: 1depth, t: 1sample];
        pooled.dimensions == [x: 31channel, y: 31channel, z: 1depth, t: 1sample];
        activation.c0 >= 0.0 forall elements;   -- ReLU invariant
        pooled.c0 >= 0.0 forall elements;        -- max of non-negatives is non-negative

    temporal invariant:
        always (sensor_input.written ⇒ eventually activation.written);
        always (activation.written ⇒ eventually pooled.written);
end

-- Multi-layer feature extractor (pipeline of conv layers)
region input_1:   region neural [x: 64channel, y: 64channel, z: 1depth, t: B batch] of F32x4 @ ShortTerm;
region feature_1: region neural [x: 31channel, y: 31channel, z: 1depth, t: B batch] of F32x4 @ ShortTerm;
region feature_2: region neural [x: 14channel, y: 14channel, z: 1depth, t: B batch] of F32x4 @ ShortTerm;
region feature_3: region neural [x: 6channel, y: 6channel, z: 1depth, t: B batch] of F32x4 @ ShortTerm;

process feature_extractor:
    reads  input_1;
    writes feature_1, feature_2, feature_3;

    when input_1 changes:
        -- Layer 1: 64×64 → 31×31
        convolve kernel_1 over input_1 into feature_1 with relu;
        pool feature_1 by 2 into feature_1;

        -- Layer 2: 31×31 → 14×14
        convolve kernel_2 over feature_1 into feature_2 with relu;
        pool feature_2 by 2 into feature_2;

        -- Layer 3: 14×14 → 6×6
        convolve kernel_3 over feature_2 into feature_3 with relu;

    ensures:
        feature_3.dimensions == [x: 6channel, y: 6channel, z: 1depth, t: B batch];
        feature_1.c0 >= 0.0 forall elements;
        feature_2.c0 >= 0.0 forall elements;
        feature_3.c0 >= 0.0 forall elements;
end