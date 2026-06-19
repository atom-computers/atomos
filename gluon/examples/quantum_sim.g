-- Quantum Simulation: wavefunction evolution and measurement
-- Demonstrates: F32x4 quantum context, evolve, measure, formal verification

region psi:          region quantum [x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of F32x4
    @ ShortTerm @ ReadWrite;
region hamiltonian:  region quantum [x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of F32x4
    @ LongTerm @ ReadOnly;
region observables:  region quantum [x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of F32x4
    @ ShortTerm @ ReadWrite;
region measurement:  region quantum [x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of U8x4
    @ ShortTerm @ ReadWrite;

process quantum_sim:
    reads  hamiltonian;
    writes psi, observables, measurement;
    private prob_cache: region quantum [x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of F32x4
        @ ShortTerm;

    every 1ms:
        -- Evolve the wavefunction under the Hamiltonian
        evolve psi by hamiltonian for 0.001;

        -- Extract observables (probability density, expectation values)
        extract_observables from psi into observables;

        -- Measure (collapse superposition)
        measure psi into measurement;

    requires:
        |psi|.[x: *, y: *, z: *, t: 0].prob_sum ≈ 1.0 within 1e-6;

    ensures:
        |psi|.[x: *, y: *, z: *, t: *].prob_sum ≈ 1.0 within 1e-6;
        observables.prob >= 0.0 forall points;
        measurement is finite forall elements;

    temporal invariant:
        always (hamiltonian.written ⇒ eventually psi.written);
        always (psi.written ⇒ eventually observables.written);
end

-- Single-qubit Hadamard gate
region qubit_in:  region quantum [x: 2qubit, y: 1, z: 1, t: 1step] of F32x4 @ ShortTerm;
region qubit_out: region quantum [x: 2qubit, y: 1, z: 1, t: 1step] of F32x4 @ ShortTerm;

process hadamard_gate:
    reads  qubit_in;
    writes qubit_out;
    private H: region quantum [x: 2qubit, y: 2qubit, z: 1, t: 1step] of F32x4 @ LongTerm;

    when qubit_in changes:
        evolve qubit_in by H for 1.0 into qubit_out;

    requires:
        qubit_in.prob_sum ≈ 1.0 within 1e-6;

    ensures:
        qubit_out.prob_sum ≈ 1.0 within 1e-6;
end