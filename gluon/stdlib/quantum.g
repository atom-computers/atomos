-- Gluon Standard Library: Quantum
-- Quantum computing primitives: evolution, measurement, entanglement.
-- All operations work on F32x4 spatial regions where components are
-- [real, imaginary, probability, phase].

-- Unitary evolution: state = U * state where U = exp(-i * H * dt / hbar)
-- H is the Hamiltonian, dt is the timestep.
process evolve_unitary:
    reads state: region quantum [x: Nx qubit, y: Ny qubit, z: Nz qubit, t: 1step] of F32x4 @ ShortTerm @ ReadWrite
    reads hamiltonian: region quantum [x: Nx qubit, y: Ny qubit, z: Nz qubit, t: 1step] of F32x4 @ LongTerm @ ReadOnly
    private dt: f32 = 0.001

    every 1ms:
        -- For each lattice point, compute U * psi
        -- U = cos(H * dt) - i * sin(H * dt) (first-order Trotter)
        -- In F32x4: [real_out, imag_out, prob_out, phase_out]
        for each (i, j, k) in state[x: *, y: *, z: *, t: 0]:
            let h = hamiltonian[x: i, y: j, z: k, t: 0];
            let psi = state[x: i, y: j, z: k, t: 0];

            -- First-order unitary: psi' = psi * cos(H*dt) - i * psi * sin(H*dt)
            let h_real = h.c0;
            let h_imag = h.c1;
            let psi_real = psi.c0;
            let psi_imag = psi.c1;
            let angle = dt * sqrt(h_real * h_real + h_imag * h_imag);
            let cos_a = cos(angle);
            let sin_a = sin(angle);

            let out_real = psi_real * cos_a + psi_imag * sin_a;
            let out_imag = psi_imag * cos_a - psi_real * sin_a;
            let out_prob = out_real * out_real + out_imag * out_imag;
            let out_phase = atan2(out_imag, out_real);

            state[x: i, y: j, z: k, t: 0] := [out_real, out_imag, out_prob, out_phase];
        end

    ensures:
        sum(state.prob) ≈ 1.0 within 1e-6 forall timesteps;
        state.is_finite forall elements;
end

-- Measure: collapse a quantum state into classical outcomes
-- For each qubit position, compute total probability, then sample
-- a binary outcome (0 or 1) based on the probability amplitude.
process measure_state:
    reads state: region quantum [x: Nx qubit, y: Ny qubit, z: Nz qubit, t: 1step] of F32x4 @ ShortTerm @ ReadWrite
    writes classical: region quantum [x: Nx qubit, y: Ny qubit, z: Nz qubit, t: 1step] of U8x4 @ ShortTerm @ ReadWrite
    private rand: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when state changes:
        for each (i, j, k) in state[x: *, y: *, z: *, t: 0]:
            let psi = state[x: i, y: j, z: k, t: 0];
            let prob = psi.c2;  -- probability amplitude from evolution

            -- Sample: if random < prob, outcome=1, else outcome=0
            let r = rand[x: 0, y: 0, z: 0, t: 0].c0;
            let outcome = if r < prob then 1u8 else 0u8;

            -- Collapse: set state to eigenstate
            let collapsed_real = if outcome == 1 then psi.c0 else 0.0;
            let collapsed_imag = if outcome == 1 then psi.c1 else 0.0;

            state[x: i, y: j, z: k, t: 0] := [collapsed_real, collapsed_imag, 0.0, 0.0];
            classical[x: i, y: j, z: k, t: 0] := [outcome, 0, 0, 0];
        end

    ensures:
        classical.c0 == 0 or classical.c0 == 1 forall elements;
        state.is_finite forall elements;
end

-- Partial trace: trace out a subsystem from a composite quantum state
-- Computes rho_A = Tr_B(rho_AB) for a bipartite system
process partial_trace:
    reads combined: region quantum [x: Na qubit, y: Nb qubit, z: 1, t: 1step] of F32x4 @ ShortTerm @ ReadOnly
    writes traced: region quantum [x: Na qubit, y: Na qubit, z: 1, t: 1step] of F32x4 @ ShortTerm @ ReadWrite

    when combined changes:
        -- Sum over the B subsystem: traced[i][k] = sum_j combined[i][j] * conj(combined[k][j])
        for each (i, k) in traced[x: *, y: *, z: 0, t: 0]:
            let mut sum_real = 0.0;
            let mut sum_imag = 0.0;
            for each j in 0..Nb:
                let elem_ik = combined[x: i, y: j, z: 0, t: 0];
                let elem_kj = combined[x: k, y: j, z: 0, t: 0];
                sum_real := sum_real + elem_ik.c0 * elem_kj.c0 + elem_ik.c1 * elem_kj.c1;
                sum_imag := sum_imag + elem_ik.c0 * elem_kj.c1 - elem_ik.c1 * elem_kj.c0;
            end
            traced[x: i, y: k, z: 0, t: 0] := [sum_real, sum_imag, 0.0, 0.0];
        end

    ensures:
        traced.is_finite forall elements;
end