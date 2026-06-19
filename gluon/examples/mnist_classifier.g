-- MNIST Classifier: full CNN + training loop + inference
-- Demonstrates: ML pipeline, convolve, pool, matmul, softmax, backward, training loop

-- Forward pass regions
region images:  region neural [x: 28 px, y: 28 px, z: 1 chan, t: B batch] of F32x4 @ ShortTerm;
region c1:     region neural [x: 24 px, y: 24 px, z: 32 chan, t: B batch] of F32x4 @ ShortTerm;
region p1:     region neural [x: 12 px, y: 12 px, z: 32 chan, t: B batch] of F32x4 @ ShortTerm;
region c2:     region neural [x: 8 px,  y: 8 px,  z: 64 chan, t: B batch] of F32x4 @ ShortTerm;
region p2:     region neural [x: 4 px,  y: 4 px,  z: 64 chan, t: B batch] of F32x4 @ ShortTerm;
region flat:    region neural [x: 1024 feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region fc1:    region neural [x: 128 feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region logits: region neural [x: 10 class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region probs:  region neural [x: 10 class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;

-- Training regions
region labels:  region[x: B batch, y: 1, z: 1, t: 1] of Raw @ LongTerm @ ReadOnly;
region loss_val: region neural [x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm;

process mnist_forward:
    reads  images;
    writes c1, p1, c2, p2, flat, fc1, logits, probs;

    when images changes:
        -- Conv block 1: 28×28 → 24×24 → 12×12
        convolve kernel[x: 5px, y: 5px, z: 1chan, t: 32chan] over images into c1 with relu;
        pool c1 by 2 into p1;

        -- Conv block 2: 12×12 → 8×8 → 4×4
        convolve kernel[x: 5px, y: 5px, z: 32chan, t: 64chan] over p1 into c2 with relu;
        pool c2 by 2 into p2;

        -- Flatten: 4×4×64 = 1024 features
        reshape p2 into flat;

        -- FC layers
        matmul flat through fc_weights into fc1;
        relu fc1 in place;

        matmul fc1 through classifier_weights into logits;
        softmax logits into probs;

    ensures:
        sum(probs[x: *, y: 0, z: 0, t: b].c0) ≈ 1.0 within 1e-6 forall b in 0..B;
        probs.c0 >= 0.0 forall elements;
        c1.dimensions == [x: 24 px, y: 24 px, z: 32 chan, t: B batch];
        p1.dimensions == [x: 12 px, y: 12 px, z: 32 chan, t: B batch];
        p2.dimensions == [x: 4 px, y: 4 px, z: 64 chan, t: B batch];
        flat.dimensions == [x: 1024 feat, y: 1, z: 1, t: B batch];
        fc1.dimensions == [x: 128 feat, y: 1, z: 1, t: B batch];
        logits.dimensions == [x: 10 class, y: 1, z: 1, t: B batch];
end

process train:
    reads  images @ ReadOnly
    reads  labels @ ReadOnly
    writes loss_val, images;

    private epoch_count: u32 = 0;
    private batch_idx: u32 = 0;

    for epoch in 0..10:
        shuffle training_data;
        for batch in training_data as chunks_of(32 batch):
            -- Write batch to input region (triggers forward pass)
            copy batch.images to images;

            -- Compute cross-entropy loss
            let correct = gather(probs, batch.labels);
            loss_val[0][0] := [-mean(log(correct.c0)), 0, 0, 0];

            -- Backward pass: compute gradients and update weights
            backward loss_val through mnist_forward into grads;
            step adam(lr: 0.001) on grads into all weight regions;
        end
        epoch_count := epoch_count + 1;
    end

    requires:
        images.prob_sum ≈ 1.0 within 1e-6 forall batch;

    ensures:
        loss_val[0][0].c0 >= 0.0;            -- cross-entropy is non-negative
        loss_val[0][0].c0 <= 10.0;            -- reasonable upper bound
        all_weights.is_finite;                -- no NaN/Inf from overflow
        probs.c0 >= 0.0 forall elements;      -- softmax non-negative
end

process classify:
    reads  single_image: region neural [x: 28 px, y: 28 px, z: 1 chan, t: 1] of F32x4 @ ReadOnly;
    writes result: region neural [x: 10 class, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm;

    when single_image changes:
        -- Copy single image to input region with batch size 1
        copy single_image to images[x: *, y: *, z: *, t: 0];

        -- Forward chain activates automatically via subscriptions
        -- Read result from predictions
        copy probs[x: *, y: 0, z: 0, t: 0] to result;

    ensures:
        sum(result.c0) ≈ 1.0 within 1e-6;
        result[x: argmax(result.c0)].c0 >= result.c0 forall elements;

    temporal invariant:
        always (single_image.written ⇒ eventually result.written within 33ms);
end