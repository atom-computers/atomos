# Gluon

A standalone, statically-typed, verified programming language designed for the Atom OS kernel model. Gluon compiles to WebAssembly and runs as reactive processes on the kernel.

## Philosophy

Gluon is built on three axioms:

**Axiom 1 — Everything is a Region.** All data lives in typed, dimensioned, tiered regions. There are no variables, pointers, objects, or files — only regions and projections between them.

**Axiom 2 — Computation is Reactive.** Programs are processes that declare what they read and what they write. The kernel wakes a process when its inputs change. No threads, no polling, no event loops.

**Axiom 3 — Correctness is Proven.** Every process carries machine-checked contracts. The compiler proves bounds safety, dimensional consistency, and user-specified invariants at build time.

## Quick Example

```gluon
region shared:  region[len: 16byte] of Raw @ ShortTerm;
region tick:    region[len: 1byte] of Raw @ ShortTerm;

process producer:
    reads  tick @ ReadOnly;
    writes shared;
    private counter: u32 = 0;

    when tick changes:
        counter := counter + 1;
        shared[0..4] := counter.to_le_bytes();
end
```

## Key Features

- **Regions as values** — typed, named-axis data volumes (`region[x: 1920px, y: 1080px, t: 2frames] of U8x4`)
- **Reactivity by default** — `when X changes, compute Y` is the control flow
- **Dimensional type system** — `px + ms` is a compile error; named axes prevent transposition bugs
- **SMT-based verification** — `requires`/`ensures` contracts proven at compile time via Z3
- **Temporal model checking** — reactive liveness/safety properties verified across process graphs
- **Capability safety** — `ReadOnly`/`ReadWrite` enforced in the type system, not at runtime
- **4D-native** — spatial regions with x, y, z, t axes cover graphics, quantum, neural, and sensor data
- **WASM target** — compiles to WebAssembly, runs on any kernel implementing the `Kernel` trait

## Architecture

```
Source (.g)
    │
    ▼
┌─────────┐    ┌──────────┐    ┌──────────┐
│ Parser  │ →  │ Checker  │ →  │ Verifier │
│ (CST)   │    │ (types,  │    │ (SMT,    │
│         │    │  dims,   │    │  temporal)│
│         │    │  caps)   │    │          │
└─────────┘    └──────────┘    └──────────┘
                                    │
                                    ▼
                               ┌──────────┐
                               │ Codegen  │
                               │ (WASM)   │
                               └──────────┘
```

## File Extension

Gluon source files use the `.g` extension.

## Documentation

- [Language Reference](../docs/gluon_language_reference.md) — full grammar, type system, verification semantics
- [Implementation Roadmap](TASKLIST.md) — phased compiler development plan

## License

MIT
