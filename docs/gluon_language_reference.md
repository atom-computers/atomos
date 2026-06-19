# Gluon Language Reference Manual

**Version 0.1.0 — Specification Phase**

---

## 1. Introduction & Philosophy

Gluon is a standalone, statically-typed, verified programming language designed for the Atom OS kernel model. The language has three foundational axioms:

**Axiom 1 — Everything is a Region.** All data lives in typed, dimensioned, tiered regions. There are no variables, pointers, objects, or files — only regions and projections between them.

**Axiom 2 — Computation is Reactive.** Programs are processes that declare what they read and what they write. The kernel wakes a process when its inputs change. No threads, no polling, no event loops — only dataflow.

**Axiom 3 — Correctness is Proven.** Every process carries machine-checked contracts. The compiler proves bounds safety, dimensional consistency, and user-specified invariants at build time using SMT solving and temporal model checking. Verified programs carry no runtime checks.

### 1.1 Design Goals

| Goal | Mechanism |
|---|---|
| Zero runtime bounds errors | SMT-proved array access |
| No dimensional mistakes | Named axes with unit types |
| Deadlock-free concurrency | Dataflow activation (no locks, no threads) |
| Capability safety proven statically | Access qualifiers in the type system |
| Reactive liveness guaranteed | Temporal model checking of the process graph |
| Natural readability | Hybrid English/math syntax |
| Hardware-portable | Compiles to WASM; kernel handles hardware |
| UI-native | Widget = process, layout = matrix, compose = blend |
| ML-native | Layer = process, forward = chain, training = process |

### 1.2 Relationship to the Kernel

```
┌──────────────────────────────────────────┐
│  Gluon source (.g)  →  gluon  →  .wasm  │
└──────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────┐
│  Kernel::spawn(Process {                │
│      program: wasm_region,               │
│      inputs:  [...],   // from "reads"   │
│      outputs: [...],   // from "writes"  │
│      private: [...],   // from "private" │
│  })                                     │
└──────────────────────────────────────────┘
```

The compiler reads the `reads`/`writes`/`private` declarations from source and produces the `Process` descriptor alongside the WASM binary. The kernel never interprets Gluon — it only runs WASM and manages regions.

---

## 2. Lexical Structure

### 2.1 Character Set

Gluon source is UTF-8. Unicode is allowed in identifiers (unit names like `µm`, `ms`, `°`).

### 2.2 Tokens

```
WHITESPACE  ::= ' ' | '\t' | '\n' | '\r'
COMMENT     ::= '--' .* '\n'
DOC_COMMENT ::= '---' .* '\n'

IDENT       ::= [a-zA-Z_][a-zA-Z0-9_]* | Unicode letter followed by letters/digits
UNIT_IDENT  ::= [a-zA-Z_][a-zA-Z0-9_]* | Unicode sequence including letters, digits, symbols
TYPE_IDENT  ::= [A-Z][a-zA-Z0-9_]*
AXIS_IDENT  ::= [a-z][a-zA-Z0-9_]*

INT_LIT     ::= [0-9]+ | '0x' [0-9a-fA-F]+
FLOAT_LIT   ::= [0-9]+ '.' [0-9]+ ([eE] [+-]? [0-9]+)?
COLOR_LIT   ::= '#' [0-9a-fA-F]{6} | '#' [0-9a-fA-F]{8}
STRING_LIT  ::= '"' .* '"'
BOOL_LIT    ::= 'true' | 'false'

KEYWORDS    ::= 'process' | 'region' | 'reads' | 'writes' | 'private'
              | 'when' | 'every' | 'on' | 'call' | 'changes' | 'ms' | 's' | 'ns'
              | 'ensures' | 'requires' | 'invariant' | 'temporal' | 'always'
              | 'eventually' | 'until' | 'next' | 'forall' | 'exists'
              | 'if' | 'then' | 'else' | 'for' | 'each' | 'in' | 'while'
              | 'and' | 'or' | 'not' | 'is' | 'as' | 'of' | 'at' | 'to' | 'with'
              | 'true' | 'false' | 'return' | 'let' | 'assert' | 'assume'
              | 'end' | 'kill' | 'self'
              | 'ShortTerm' | 'LongTerm' | 'ReadOnly' | 'ReadWrite'
              | 'U8x4' | 'F32x4' | 'U16x4' | 'Raw' | 'Spatial'
              | 'migrate' | 'persist' | 'project' | 'blend' | 'evolve'
              | 'convolve' | 'broadcast' | 'reshape' | 'compose' | 'draw'
              | 'fill' | 'clear' | 'swap' | 'spawn' | 'grant' | 'revoke'
              | 'into' | 'over' | 'onto' | 'through' | 'from' | 'by' | 'for'

OPERATORS   ::= '+' | '-' | '*' | '/' | '%' | '^'
              | '==' | '!=' | '<' | '>' | '<=' | '>='
              | ':=' | '=' | ':' | '×' | '→' | '≈'
              | 'and' | 'or' | 'not' | 'in'
              | '.' | ',' | ';' | '(' | ')' | '[' | ']' | '{' | '}'
              | '@' | '|' | '&' | '<<' | '>>'
```

### 2.3 Number Literals with Units

```
let frame_time = 16.0ms       -- parsed as (16.0, unit: ms)
let width      = 1920px        -- parsed as (1920, unit: px)
let angle      = 90°           -- parsed as (90, unit: degree)
let rate       = 60fps         -- parsed as (60, unit: fps)
let duration   = 5s            -- parsed as (5, unit: s)
```

### 2.4 Dimensional Product Notation

```
1920px × 1080px                        -- a 2D extent, type: px²
256qubit × 256qubit × 256qubit          -- a 3D extent, type: qubit³
1920px × 1080px × 1layer × 2frames     -- a 4D extent
```

---

## 3. Core Types

### 3.1 Scalar Types

```
Scalar ::= 'u8' | 'u16' | 'u32' | 'u64' | 'i8' | 'i16' | 'i32' | 'i64'
         | 'f32' | 'f64' | 'bool'
```

### 3.2 Element Types

```
ElementFormat ::= 'U8x4'      -- 4 bytes: four u8 components
                | 'F32x4'     -- 16 bytes: four f32 components
                | 'U16x4'     -- 8 bytes: four u16 components
```

#### Element Component Access

Each `ElementFormat` has context-dependent component naming:

| Context | U8x4 | F32x4 |
|---|---|---|
| `graphics` | `[r, g, b, a]` | `[x, y, z, w]` |
| `input` | `[pressed, repeat, mods, reserved]` | `[active, pressure, contact, reserved]` |
| `quantum` | — | `[real, imag, prob, phase]` |
| `neural` | — | `[voltage, field, coherence, quality]` |
| `dna` | `[a, t, g, c]` | `[a_prob, t_prob, g_prob, c_prob]` |
| _(none)_ | `[c0, c1, c2, c3]` | `[c0, c1, c2, c3]` |

```
let pixel: U8x4 = [r: 255, g: 128, b: 64, a: 255]
let amp:   F32x4 = [real: 0.707, imag: 0.707, prob: 0.5, phase: 1.571]
```

### 3.3 Region Type

The region type is the central type of Gluon:

```
RegionType ::= 'region' '[' DimensionSpec ']' 'of' ElementFormat
             ('@' Tier)? ('@' Access)?

DimensionSpec ::= AxisSpec (',' AxisSpec)*

AxisSpec ::= AXIS_IDENT ':' (INT_LIT | TYPE_VAR) UNIT_IDENT

Tier    ::= 'ShortTerm' | 'LongTerm'
Access  ::= 'ReadOnly' | 'ReadWrite'
```

Examples:
```
region[x: 1920px, y: 1080px, z: 1layer, t: 2frames] of U8x4 @ ShortTerm @ ReadWrite
region[x: N px, y: M px] of F32x4 @ LongTerm
region[x: 256scancode, y: 1row, z: 1layer, t: 1frame] of U8x4
region[len: 4096byte] of Raw @ LongTerm
```

### 3.4 Matrix Type

```
MatrixType ::= 'matrix' '<' '[' DimensionSpec ']' '→' '[' DimensionSpec ']' '>'
```

Examples:
```
matrix<[x: px, y: px, z: px, w: homogeneous] → [x: ndc, y: ndc, z: ndc, w: homogeneous]>
matrix<[x: qubit, y: qubit] → [x: qubit, y: qubit]>
```

### 3.5 Unit Types

Units form an abelian group under multiplication. The type checker performs dimensional analysis:

```
UNIT ::= base_unit | UNIT '*' UNIT | UNIT '/' UNIT | UNIT '^' INT | 'dimensionless'

base_unit ::= 'px' | 'frame' | 'qubit' | 'step' | 'ms' | 's' | 'ns' | 'byte'
            | 'scancode' | 'layer' | 'sample' | 'channel' | 'base'
            | 'read' | 'chromosome' | 'electrode' | 'depth'
            | '°' | 'rad' | 'fps' | 'nm' | 'µm' | 'm'
            | 'batch' | 'feat' | 'class' | 'vertex'
            | UNIT_IDENT              -- user-defined unit
```

**Rules:**
- Addition/subtraction requires identical units: `px + px = px`
- Multiplication multiplies units: `px * px = px²`
- Division divides units: `px / ms = px·ms⁻¹`
- Comparison (`<`, `>`) requires identical units
- Transcendental functions (`sin`, `cos`, `exp`) require `dimensionless` input
- Unit mismatches are **compile-time errors**

```
let area = 1920px * 1080px     -- type: px² (ok)
let bad  = 1920px + 5ms       -- COMPILE ERROR: cannot add px and ms
let ok   = sin(pi/2)           -- ok: dimensionless argument
```

### 3.6 Refinement Types

Types can be refined with predicates:

```
Refinement ::= Type 'where' Predicate

Predicate ::= Expr COMPARATOR Expr
            | Predicate 'and' Predicate
            | Predicate 'or' Predicate
            | 'not' Predicate
            | 'forall' '(' BoundVar ':' Type ')' Predicate
            | 'exists' '(' BoundVar ':' Type ')' Predicate
            | '(' Predicate ')'

BoundVar  ::= IDENT | 'i' | 'j' | 'k' | 'x' | 'y' | 'z' | 't'
```

Examples:
```
width: u32 where width > 0 and width <= 1920
pixel: U8x4 where pixel.r <= 127 and pixel.g <= 127 and pixel.b <= 127
framebuffer: region[x: 1920px, y: 1080px] of U8x4 where framebuffer[0][0].a == 255
```

---

## 4. Region Declarations

### 4.1 Global Region Declaration

```
RegionDecl ::= 'region' IDENT ':' RegionType ';'
```

Global regions exist before the process is spawned (created by the system, a parent process, or a driver):

```
region framebuffer: region[x: 1920px, y: 1080px, z: 1layer, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

region touch_input: region[x: 1920px, y: 1080px, z: 1layer, t: 1frame] of F32x4
    @ ShortTerm @ ReadOnly;

region quantum_state: region[x: 256qubit, y: 256qubit, z: 256qubit, t: 1step] of F32x4
    @ ShortTerm @ ReadWrite;
```

### 4.2 Runtime Region Creation

```
let temp = create region[x: 1024px, y: 768px] of U8x4 @ ShortTerm;
```

Dynamic regions are destroyed when the creating process exits, unless explicitly persisted or granted to another process.

### 4.3 Semantic Context Annotations

A region can declare its semantic context to influence element component naming:

```
region framebuffer: region graphics [x: 1920px, y: 1080px] of U8x4;
region psi:        region quantum [x: 256qubit, y: 256qubit] of F32x4;
region sensor:     region neural [x: 64channel, y: 64channel] of F32x4;
region keys:       region input [x: 256scancode] of U8x4;
```

Available semantic contexts: `graphics`, `input`, `quantum`, `neural`, `dna`.

---

## 5. Processes

### 5.1 Process Declaration

```
ProcessDecl ::= 'process' IDENT (':' NEWLINE
                ReadDecls
                WriteDecls
                PrivateDecls
                ConstraintDecls
                ContractBlock
                ReactBlock+
              'end')?

ReadDecl    ::= 'reads'  IDENT ('@' Access)? (',' IDENT ('@' Access)?)* ';'
WriteDecl   ::= 'writes' IDENT ('@' Access)? (',' IDENT ('@' Access)?)* ';'
PrivateDecl ::= 'private' IDENT (':' Type)? ('=' Expr)? (',' IDENT (':' Type)? ('=' Expr)?)* ';'

ConstraintDecl ::= 'constrains' IDENT ':' Predicate ';'

ContractBlock ::= RequiresBlock? EnsuresBlock?

RequiresBlock ::= 'requires' ':' Predicate (';' Predicate)*
EnsuresBlock  ::= 'ensures' ':' Predicate (';' Predicate)*
```

**Full example:**

```
process compositor:
    reads  framebuffer, ui_overlay, touch;
    writes framebuffer;
    private scratch: region[x: 1920px, y: 1080px] of U8x4 @ ShortTerm;
    constrains framebuffer: framebuffer[t: 1].a == 255 forall pixels;

    when touch changes:
        clear framebuffer[t: current] to #27292A;
        render ui_overlay into scratch;
        blend scratch over framebuffer[t: current];

    every 16ms:
        swap framebuffer[t: current] with framebuffer[t: next];

    ensures:
        framebuffer[t: scanned].a == 255 forall pixels;
        scratch.dimensions == framebuffer[t: current].dimensions;

    temporal invariant:
        always (framebuffer[t: 0] is not (being_written and being_scanned));
        always (touch.written ⇒ eventually framebuffer.written);
end
```

### 5.2 React Blocks

```
ReactBlock ::= WhenBlock | EveryBlock | CallBlock

WhenBlock   ::= 'when' IDENT ('or' IDENT)* 'changes' ':'
                Statement*

EveryBlock  ::= 'every' FLOAT_LIT ('ms' | 's' | 'ns' | 'µs') ':'
                Statement*

CallBlock   ::= 'on' 'call' '(' IDENT (':' Type)? ',' IDENT (':' Type)? ')' ':' VALUE '→' Type
                Statement*
```

| Mode | Syntax | Semantics |
|---|---|---|
| **Dataflow** | `when X changes:` | Reactive: wakes when subscribed input writes |
| **Periodic** | `every 16ms:` | Timer-driven: for vsync, sensor polling |
| **On-demand** | `on call(...):` | RPC-style: invoked by capability-bearing caller |

### 5.3 Process Composition

```
let child_pid = spawn tracker_process with (
    reads:  [sensor_data @ ReadOnly],
    writes: [alert_region],
);
```

The `spawn` expression returns a `ProcessId`. The parent retains the ability to `grant`, `revoke`, or `kill` the child.

### 5.4 Process Termination

```
kill self;     -- terminate this process
kill child_pid; -- terminate a child process
```

---

## 6. Expressions

### 6.1 Expression Grammar

```
Expr ::= PrimaryExpr
       | UnaryExpr
       | BinaryExpr
       | RegionExpr
       | MatrixExpr
       | IfExpr
       | ForExpr
       | LetExpr

PrimaryExpr ::= INT_LIT | FLOAT_LIT | COLOR_LIT | STRING_LIT | BOOL_LIT
              | IDENT
              | IDENT '[' AxisIndex (',' AxisIndex)* ']'
              | IDENT '.' COMPONENT
              | '(' Expr ')'
              | 'create' 'region' '[' DimensionSpec ']' 'of' ElementFormat ('@' Tier)?
              | '|' Expr '|'
              | '[' Expr (',' Expr)* ']'         -- element literal
              | MatrixLiteral

UnaryExpr ::= '-' Expr
            | 'not' Expr

BinaryExpr ::= Expr ('+' | '-' | '*' | '/' | '%' | '^' | '×') Expr
             | Expr ('==' | '!=' | '<' | '>' | '<=' | '>=' | '≈') Expr
             | Expr 'and' Expr
             | Expr 'or' Expr

RegionExpr ::= IDENT '[' AxisIndex (',' AxisIndex)* ']' ':=' Expr ';'
             | IDENT '[' RegionSlice ']'

MatrixExpr ::= IDENT 'through' IDENT
             | 'project' IDENT 'through' IDENT 'onto' IDENT
             | 'blend' IDENT 'over' IDENT ('into' IDENT)?
             | 'evolve' IDENT 'by' IDENT 'for' Expr
             | 'convolve' IDENT 'over' IDENT ('into' IDENT)?
             | 'matmul' IDENT 'through' IDENT 'into' IDENT

AxisIndex   ::= AXIS_IDENT ':' Expr
AxisSlice   ::= AXIS_IDENT ':' (Expr | Expr '..' Expr | Expr '..' | '..' Expr | '..' | '*')

IfExpr      ::= 'if' Expr ':' Block ('else' 'if' Expr ':' Block)* ('else' ':' Block)? 'end'

ForExpr     ::= 'for' 'each' '(' IDENT (',' IDENT)* ')' 'in' RegionSlice ':' Block 'end'

LetExpr     ::= 'let' IDENT (':' Type)? '=' Expr ';'
```

### 6.2 Region Element Access

```
let pixel    = framebuffer[x: 100, y: 200, z: 0, t: 0];
let row      = framebuffer[x: 0..1920, y: 100, z: 0, t: 0];
let frame    = framebuffer[x: *, y: *, z: 0, t: 0];
let channel  = signal[x: 0, y: 0..256, z: 0, t: current];

-- Write:
framebuffer[x: 100, y: 200, z: 0, t: 0] := [r: 255, g: 0, b: 0, a: 255];
```

Axis names are used as accessor keys to prevent x/y transposition bugs and enable dimensional type checking.

### 6.3 Matrix Operations

```
let view       = look_at(eye, center, up);
let projection = perspective(fov: 60°, aspect: 16/9, near: 0.1m, far: 100m);

let ndc_point  = projection * view * world_point;
let world_back = inverse(view) * ndc_point;

let combined   = translation * rotation * scale;
```

### 6.4 Built-in Domain Operators

```
-- Graphics
project vertices through transform onto framebuffer;
blend source over destination into result;
clear framebuffer[t: current] to #27292A;

-- Quantum
evolve wavefunction by hamiltonian for 0.001;
measure psi into classical;
entangle qubit_a with qubit_b;

-- Neural / Signal processing
convolve kernel over signal into result;
pool activation by 2 into pooled;
matmul input through weights into output;
broadcast_add bias to output;
softmax logits into probabilities;

-- Memory
migrate region from ShortTerm to LongTerm;
persist region;
reshape source into target;
copy source to target;
```

| Domain | Built-in | Operands |
|---|---|---|
| Graphics | `project`, `blend`, `clear`, `swap` | `U8x4` regions |
| Quantum | `evolve`, `measure`, `entangle` | `F32x4` regions |
| Neural | `convolve`, `pool`, `matmul`, `broadcast_add`, `softmax`, `relu` | `F32x4` regions |
| General | `migrate`, `persist`, `reshape`, `copy`, `fill`, `draw_text` | Any regions |

### 6.5 Standard Library Functions

```
-- Math (dimensionless inputs unless noted)
sin(x: f64) → f64
cos(x: f64) → f64
tan(x: f64) → f64
exp(x: f64) → f64
log(x: f64) → f64 where x > 0
sqrt(x: f64) → f64 where x >= 0
abs(x: f64) → f64
min(a: T, b: T) → T
max(a: T, b: T) → T
clamp(x: T, lo: T, hi: T) → T where lo <= hi
sum(region_slice) → f64
mean(region_slice) → f64
argmax(region_slice) → idx

-- Matrix construction
identity<D>() → matrix<D → D>
translate(x: f64 @ m, y: f64 @ m, z: f64 @ m) → matrix<...>
scale(sx: f64, sy: f64, sz: f64) → matrix<...>
rotate_x(angle: f64) → matrix<...>
rotate_y(angle: f64) → matrix<...>
rotate_z(angle: f64) → matrix<...>
perspective(fov: f64, aspect: f64, near: f64 @ m, far: f64 @ m) → matrix<...>
orthographic(...) → matrix<...>
look_at(eye, center, up) → matrix<...>

-- Region utilities
clear(region, value)
copy(src, dst) where src.dimensions == dst.dimensions
fill(region, slice, value)
swap(a, b)
```

---

## 7. Formal Verification

Gluon provides two complementary verification layers, both checked at compile time.

### 7.1 Refinement Types & Contracts (SMT-based)

#### Process Contracts

```
process name:
    reads ...;
    writes ...;

    requires:
        -- Preconditions: must hold when the process is activated
        input[x: 0].a == 255;
        N > 0;

    -- ... reactive blocks ...

    ensures:
        -- Postconditions: must hold when the process yields
        output[t: current].a == 255 forall pixels;
        output.dimensions == input.dimensions;
        sum(observables.prob) ≈ 1.0 within 1e-6;
end
```

The SMT solver proves that for all inputs satisfying `requires`, the reactive blocks produce outputs satisfying `ensures`. If proof fails, the compiler emits a counterexample.

#### Invariants on Regions

```
region framebuffer: region[x: 1920px, y: 1080px] of U8x4
    invariant: framebuffer[t: scanned].a == 255 forall pixels;
    invariant: framebuffer[t: 0] is not (being_written and being_scanned);
```

Invariants must be preserved by every process that writes to the region.

#### SMT Verification Checks

| Check | Description |
|---|---|
| **Bounds** | Every `region[x: i, y: j]` access has `0 <= i < N` and `0 <= j < M` |
| **Overflow** | `U8x4` values never exceed 255; `F32x4` values never NaN |
| **Contracts** | `requires ⇒ ensures` for every reactive block |
| **Invariants** | Every writer preserves every invariant on target region |
| **Dimensional safety** | No mixing incompatible units; matrix dimensions match |
| **Access safety** | No writes to `ReadOnly` regions; no reads of unsubscribed regions |
| **Temporal bounds** | No access to `t > declared_max` or `t < 0` |

### 7.2 Temporal Logic (Model Checking)

Temporal specifications verify reactive properties across the entire dataflow graph.

```
TemporalSpec ::= 'temporal' 'invariant' ':' TemporalExpr (';' TemporalExpr)*

TemporalExpr ::= 'always' '(' InnerExpr ')'
               | 'eventually' '(' InnerExpr ')'
               | TemporalExpr 'until' TemporalExpr
               | 'next' '(' InnerExpr ')'

InnerExpr ::= IDENT '.' 'written'
            | IDENT '.' 'being_written'
            | IDENT '.' 'being_scanned'
            | InnerExpr '⇒' InnerExpr
            | InnerExpr 'and' InnerExpr
            | InnerExpr 'or' InnerExpr
            | 'not' InnerExpr
            | 'every' 'process' 'is' 'eventually' 'activated'
            | '(' InnerExpr ')'
```

#### Example Specifications

```
temporal invariant:
    always (touch.written ⇒ eventually framebuffer.written);
    always (not (framebuffer.being_written and framebuffer.being_scanned));
    every process is eventually activated;
    always (camera.written ⇒ (not framebuffer.written until camera.written));
    always (touch.written ⇒ framebuffer.written within 33ms);
```

The compiler constructs the process graph, builds a labeled transition system (LTS), and checks LTL formulas.

---

## 8. Capability Model

### 8.1 Access Qualifiers

Access is a type-level property:

```
process renderer:
    reads  vertices @ ReadOnly;
    writes framebuffer @ ReadWrite;
    private cache @ ReadWrite;
```

The compiler enforces:
- No write to a `ReadOnly` region
- No read of a region not in `reads`, `writes`, or `private`
- No access to another process's `private` region

### 8.2 Granting and Revoking

```
grant sensor_data @ ReadOnly to tracker_process;
revoke sensor_data from tracker_process;
```

Only the region owner can grant or revoke access.

### 8.3 Capability Checking

The capability checker proves:
1. No process writes to a region it only has `ReadOnly` access to
2. A process can only `grant` access to regions it owns
3. After `revoke`, the target process can no longer access the region
4. Capabilities form a DAG (no cycles)

---

## 9. Memory Tiers

### 9.1 Tier Declarations

```
region cache:    region[x: 1024px, y: 768px] of U8x4 @ ShortTerm;
region database: region[len: 1MB] of Raw @ LongTerm;
```

| Property | ShortTerm | LongTerm |
|---|---|---|
| Volatility | Lost on power-off | Durable |
| Speed | Sub-μs access | μs–ms access |
| Capacity | Limited (physical RAM) | Large (storage) |
| Use | Working data, framebuffers, caches | User data, models, configurations |

### 9.2 Tier Migration

```
migrate cache from ShortTerm to LongTerm;
migrate database from LongTerm to ShortTerm;
persist database;
```

The compiler verifies that no process is actively reading/writing a region during migration.

---

## 10. UI Programming in Gluon

UIs in Gluon are **compositions of processes** writing to spatial regions. A widget is a process. Layout is matrix math. Display is blending sub-regions onto a framebuffer.

### 10.1 Core Concepts

| UI Concept | Gluon Equivalent |
|---|---|
| Widget | Process with `reads touch`, `writes viewport` |
| State | Private `Raw` or `Spatial` region |
| Layout (row/column) | Process that computes sub-rectangles, blends children |
| Styling | Element values: colors, spacing (dimensions with units) |
| Event handling | Read `touch` region, compute hit-test |
| Animation | `every 16ms` block writing to successive `t`-frames |
| Generative UI | Typed region schemas (`card`, `table`, `approval_request`) |
| Composition | `compose vertical on screen: [child at (x,y)]*` |

### 10.2 Button Widget

```
process button(label_text: string, width: u32 @ px, height: u32 @ px):
    reads  touch: region[x: width px, y: height px] of F32x4 @ ReadOnly
    private count: region[len: 4byte] of Raw @ ShortTerm
    writes viewport: region[x: width px, y: height px] of U8x4 @ ShortTerm @ ReadWrite

    when touch changes:
        if touch[x: *, y: *, z: 0, t: 0].active > 0.1:
            count[0..4] := (count.as_u32 + 1).to_le_bytes();

        fill viewport with color #3B82F6 radius 8px;
        draw_text viewport "×{count.as_u32}" font "Inter" size 16px color white bold center;

    ensures:
        viewport.dimensions == [x: width px, y: height px];
end
```

### 10.3 Chat UI Composition

```
process chat_screen:
    reads  touch:    region[x: W px, y: H px] of F32x4 @ ReadOnly
    reads  keyboard: region[x: 256scancode, y: 1row, z: 1layer, t: 1frame] of U8x4 @ ReadOnly
    private header_buf:   region[x: W px, y: 64 px] of U8x4 @ ShortTerm
    private message_buf:  region[x: W px, y: H-128 px] of U8x4 @ ShortTerm
    private input_buf:    region[x: W px, y: 64 px] of U8x4 @ ShortTerm
    private messages:     region[len: 1MB] of Raw @ LongTerm
    writes screen: region[x: W px, y: H px] of U8x4 @ ShortTerm @ ReadWrite

    when touch or keyboard changes:
        spawn header_bar with (reads: [keyboard], writes: [header_buf]);
        spawn message_list with (reads: [messages], writes: [message_buf]);
        spawn chat_input with (reads: [keyboard], writes: [input_buf, messages]);

        clear screen to #0F0F1A;
        compose vertical on screen:
            header_buf    at x: 0, y: 0
            message_buf    at x: 0, y: 64px weight: 1fr
            input_buf      at x: 0, y: H-64

    ensures:
        screen[t: current].all_pixels.have_alpha(255);
end
```

### 10.4 Animation via Temporal Frames

```
process fade_in(duration: 300ms):
    reads  source: region[x: W px, y: H px] of U8x4 @ ReadOnly
    writes target: region[x: W px, y: H px] of U8x4 @ ShortTerm @ ReadWrite
    private progress: region[x: 1, y: 1] of F32x4 @ ShortTerm

    every 16ms:
        let p = progress[0][0].c0 + 0.016f32;
        progress[0][0] := [min(p, 1.0), 0, 0, 0];
        blend source over target with opacity(progress[0][0].c0);
        if p >= 1.0: kill self; end
end
```

### 10.5 List View with Virtual Scrolling

```
process virtual_list(item_count: u32, item_height: u32 @ px):
    reads  items: region[x: item_count item, y: 1, z: 1, t: 1] of Raw @ LongTerm @ ReadOnly
    reads  scroll: region[x: 1, y: 1] of F32x4 @ ReadOnly
    writes viewport: region[x: W px, y: H px] of U8x4 @ ShortTerm @ ReadWrite

    when items or scroll changes:
        let offset = scroll[0][0].c1;
        let start_idx = floor(offset / item_height);
        let visible_count = ceil(H / item_height) + 1;

        clear viewport;
        for each i in start_idx..min(start_idx + visible_count, item_count):
            let top = i * item_height - offset;
            let item_view = render_item(items[x: i]);
            blit item_view into viewport at [x: 0, y: top];
        end
end
```

### 10.6 Gesture Recognition

```
process gesture_recognizer:
    reads  touch: region[x: W px, y: H px] of F32x4 @ ReadOnly
    writes gesture: region[x: 1, y: 1] of F32x4 @ ShortTerm @ ReadWrite
    private touch_history: region[x: 16frame, y: 1] of F32x4 @ ShortTerm
    private frame_idx: u32 = 0

    when touch changes:
        let contacts = count_active_contacts(touch);

        if contacts == 1:
            push touch[center_of_mass] into touch_history[frame_idx];
            frame_idx := (frame_idx + 1) % 16;

            let velocity = compute_velocity(touch_history);
            if |velocity| > swipe_threshold:
                gesture[0][0] := [1, direction(velocity), |velocity|, 0]
            else if hold_time(touch_history) > 500ms:
                gesture[0][0] := [4, hold_time(touch_history), 0, 0]
            end
        else if contacts == 2:
            let scale = compute_pinch_scale(touch);
            gesture[0][0] := [3, scale, 0, 0]
        else:
            gesture[0][0] := [0, 0, 0, 0]
        end
end
```

### 10.7 Generative UI Blocks

The generative UI system maps typed region schemas to native rendering:

```
process gen_card:
    reads  block_data: region[len: N byte] of Raw @ ReadOnly
    writes rendered: region[x: W px, y: auto px] of U8x4 @ ShortTerm @ ReadWrite

    when block_data changes:
        let card = deserialize_card(block_data);

        fill rendered with color #FFFFFF radius 12px shadow 4px;
        draw_text rendered card.title at (16px, 16px)
            font "Inter" size 18px weight bold color #1A1A2E;
        draw_text rendered card.body at (16px, 48px)
            font "Inter" size 14px color #4A4A6A;

        if card.actions exists:
            for each action in card.actions:
                draw_button rendered action.label at action.position style action.style;
            end
end
```

Block types: `card`, `table`, `approval_request`, `progress_bar`, `file_tree`, `diff_view`.

### 10.8 UI Heuristics Enforced by Type Checker

| Heuristic | Enforcement |
|---|---|
| No torn frames | Temporal invariant: `always (not (fb.being_written and fb.being_scanned))` |
| Alpha integrity | `ensures: fb[t: scanned].a == 255 forall pixels` |
| Layout overflow | Region bounds checked: child regions fit within parent |
| No mid-frame read | Double-buffering enforced by `t: current` / `t: next` swap pattern |
| Touch hit-test bounds | SMT proves touch coordinates are within viewport dimensions |
| Responsive breakpoints | Dimensional contracts: `ensures: width >= 320px and width <= 3840px` |

---

## 11. ML Programming in Gluon

ML models in Gluon are **process pipelines** transforming `F32x4` spatial regions. A layer is a process with weight regions. The forward pass is reactive dataflow. Training is a separate process that orchestrates forward and backward passes.

### 11.1 Core Concepts

| ML Concept | Gluon Equivalent |
|---|---|
| Layer | Process with `reads activation_in`, `writes activation_out`, `private weights` |
| Weights | `Spatial` region (`F32x4`) @ `LongTerm` |
| Forward pass | Reactive chain: input written → layer activates → output → next |
| Backward pass | Autodiff via dual activation process |
| Optimizer | Process reading gradients + weights, writing updated weights |
| Data loader | Process reading dataset region, writing batches |
| Inference | Single input write → chain activates → read output |

### 11.2 Linear Layer

```
process linear(in: dim feat, out: dim feat):
    reads  x: region[x: in feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    private w: region[x: in feat, y: out feat, z: 1, t: 1] of F32x4 @ LongTerm
    private b: region[x: out feat, y: 1, z: 1, t: 1] of F32x4 @ LongTerm
    writes y: region[x: out feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when x changes:
        matmul x through w into y;
        broadcast_add b to y;

    ensures:
        y.dimensions == [x: out feat, y: 1, z: 1, t: B batch];
        y.is_finite forall elements;
end
```

### 11.3 Activation Functions

```
process relu:
    reads  x: region[dims] of F32x4 @ ShortTerm
    writes y: region[dims] of F32x4 @ ShortTerm

    when x changes:
        for each elem in y:
            elem.c0 := max(elem.c0, 0.0);
        end

    ensures:
        y.c0 >= 0.0 forall elements;
        y.dimensions == x.dimensions;
end

process softmax(N: dim class, B: dim batch):
    reads  x: region[x: N class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm
    writes y: region[x: N class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm

    when x changes:
        for each b in 0..B:
            let max_val = max(x[x: *, y: 0, z: 0, t: b].c0);
            let sum_exp = sum(exp(x[x: *, y: 0, z: 0, t: b].c0 - max_val));
            for each i in 0..N:
                y[x: i, y: 0, z: 0, t: b] := [exp(x[x: i, y: 0, z: 0, t: b].c0 - max_val) / sum_exp, 0, 0, 0];
            end
        end

    ensures:
        sum(y[x: *, y: 0, z: 0, t: b].c0) ≈ 1.0 within 1e-6 forall b in 0..B;
        y.c0 >= 0.0 forall elements;
end
```

### 11.4 MNIST Classifier (Full CNN)

```
region images:   region[x: 28 px, y: 28 px, z: 1 chan, t: B batch] of F32x4 @ ShortTerm;
region c1:      region[x: 24 px, y: 24 px, z: 32 chan, t: B batch] of F32x4 @ ShortTerm;
region p1:      region[x: 12 px, y: 12 px, z: 32 chan, t: B batch] of F32x4 @ ShortTerm;
region c2:      region[x: 8 px,  y: 8 px,  z: 64 chan, t: B batch] of F32x4 @ ShortTerm;
region p2:      region[x: 4 px,  y: 4 px,  z: 64 chan, t: B batch] of F32x4 @ ShortTerm;
region flat:     region[x: 1024 feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region fc1:     region[x: 128 feat, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region logits:  region[x: 10 class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;
region probs:   region[x: 10 class, y: 1, z: 1, t: B batch] of F32x4 @ ShortTerm;

process mnist_classifier:
    reads  images;
    writes c1, p1, c2, p2, flat, fc1, logits, probs;

    when images changes:
        convolve kernel[x: 5px, y: 5px, z: 1chan, t: 32chan] over images into c1 with relu;
        pool c1 by 2 into p1;
        convolve kernel[x: 5px, y: 5px, z: 32chan, t: 64chan] over p1 into c2 with relu;
        pool c2 by 2 into p2;
        reshape p2 into flat;
        matmul flat through fc_weights into fc1;
        relu fc1 in place;
        matmul fc1 through classifier_weights into logits;
        softmax logits into probs;

    ensures:
        sum(probs[x: *, y: 0, z: 0, t: b].c0) ≈ 1.0 within 1e-6 forall b in 0..B;
end
```

### 11.5 Training Loop

```
process train(dataset: region, epochs: u32, batch_size: u32 @ batch):
    reads  images @ ReadOnly
    reads  labels: region[x: batch_size batch, y: 1] of Raw @ LongTerm @ ReadOnly
    private loss:  region[x: 1, y: 1] of F32x4 @ ShortTerm
    private grads: region matching all weight regions @ ShortTerm

    for epoch in 0..epochs:
        shuffle dataset;
        for batch in dataset as chunks_of(batch_size):
            copy batch.images to images;
            let correct = gather(probs, batch.labels);
            loss[0][0] := [-mean(log(correct.c0)), 0, 0, 0];
            backward loss through mnist_classifier into grads;
            step adam(lr: 0.001) on grads into all weight regions;
        end
    end

    ensures:
        loss[0][0].c0 >= 0.0;
        loss[0][0].c0 <= 10.0;
        all_weights.is_finite;
end
```

### 11.6 Inference

```
process classify:
    reads  single_image: region[x: 28 px, y: 28 px, z: 1 chan, t: 1] of F32x4 @ ReadOnly
    writes result: region[x: 10 class, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when single_image changes:
        copy single_image to images[x: *, y: *, z: *, t: 0];
        copy predictions[x: *, y: 0, z: 0, t: 0] to result;

    ensures:
        sum(result.c0) ≈ 1.0 within 1e-6;
        result[x: argmax(result.c0)].c0 >= result.c0 forall elements;
end
```

### 11.7 ML Heuristics Enforced by Type Checker

| Heuristic | Enforcement |
|---|---|
| Layer dimension chaining | Output dims of layer N == input dims of layer N+1 |
| Softmax sums to ~1 | `sum(probs.c0) ≈ 1.0 within 1e-6` |
| Weights are finite | `all_weights.is_finite` (no NaN/Inf) |
| Batch dimension propagates | `t: B batch` consistent through all layers |
| Convolution output size | `(input - kernel + 2*padding) / stride + 1` |
| Pooling output size | `input / stride` |
| Loss non-negativity | `loss.c0 >= 0.0` for cross-entropy |

---

## 12. Complete EBNF Grammar

```ebnf
module       ::= (region_decl | process_decl | temporal_spec)*

region_decl  ::= 'region' IDENT ':' region_type ('invariant' ':' predicate (';' predicate)*)? ';'

region_type  ::= region_kind? 'region' '[' dim_spec (',' dim_spec)* ']' 'of' element_format
                 ('@' tier)? ('@' access)?

region_kind  ::= 'graphics' | 'input' | 'quantum' | 'neural' | 'dna'

dim_spec     ::= AXIS_IDENT ':' (INT_LIT | TYPE_VAR) UNIT_IDENT

element_format ::= 'U8x4' | 'F32x4' | 'U16x4'

tier         ::= 'ShortTerm' | 'LongTerm'
access       ::= 'ReadOnly' | 'ReadWrite'

process_decl ::= 'process' IDENT (':' NEWLINE
                 read_decls write_decls private_decls constraint_decls
                 contract_block react_block+ 'end')?

read_decls   ::= ('reads' IDENT ('@' access)? (',' IDENT ('@' access)?)* ';')?
write_decls  ::= ('writes' IDENT ('@' access)? (',' IDENT ('@' access)?)* ';')?
private_decls ::= ('private' IDENT (':' type)? ('=' expr)? (',' IDENT (':' type)? ('=' expr)?)* ';')?

constraint_decls ::= ('constrains' IDENT ':' predicate ';')*
contract_block ::= requires_block? ensures_block?
requires_block ::= 'requires' ':' predicate (';' predicate)*
ensures_block  ::= 'ensures' ':' predicate (';' predicate)*

react_block  ::= when_block | every_block | call_block

when_block   ::= 'when' IDENT ('or' IDENT)* 'changes' ':' statement*
every_block  ::= 'every' FLOAT_LIT ('ms' | 's' | 'ns' | 'µs') ':' statement*
call_block   ::= 'on' 'call' '(' param (',' param)* ')' ':' type ':' statement*

statement    ::= let_stmt | assign_stmt | region_write_stmt | if_stmt
               | for_stmt | return_stmt | assert_stmt | assume_stmt
               | expr_stmt | spawn_stmt | grant_stmt | revoke_stmt
               | migrate_stmt | builtin_stmt | kill_stmt

let_stmt     ::= 'let' IDENT (':' type)? '=' expr ';'
assign_stmt  ::= IDENT ':=' expr ';'
region_write ::= IDENT '[' axis_index (',' axis_index)* ']' ':=' expr ';'
kill_stmt   ::= 'kill' ('self' | IDENT) ';'

if_stmt      ::= 'if' expr ':' statement* ('else' 'if' expr ':' statement*)* ('else' ':' statement*)? 'end'
for_stmt     ::= 'for' 'each' '(' IDENT (',' IDENT)* ')' 'in' region_slice ':' statement* 'end'

spawn_stmt   ::= 'let' IDENT '=' 'spawn' IDENT 'with' '(' spawn_args ')' ';'
spawn_args   ::= ('reads' ':' '[' IDENT ('@' access)? (',' IDENT ('@' access)?)* ']')?
                 ('writes' ':' '[' IDENT ('@' access)? (',' IDENT ('@' access)?)* ']')?

grant_stmt   ::= 'grant' IDENT '@' access 'to' IDENT ';'
revoke_stmt  ::= 'revoke' IDENT 'from' IDENT ';'
migrate_stmt ::= 'migrate' IDENT 'from' tier 'to' tier ';'

builtin_stmt ::= 'project' IDENT 'through' IDENT 'onto' IDENT ';'
               | 'blend' IDENT 'over' IDENT ('into' IDENT)? ';'
               | 'evolve' IDENT 'by' IDENT 'for' expr ';'
               | 'convolve' IDENT 'over' IDENT ('into' IDENT)? ';'
               | 'matmul' IDENT 'through' IDENT 'into' IDENT ';'
               | 'clear' IDENT 'to' (COLOR_LIT | expr) ';'
               | 'swap' IDENT 'with' IDENT ';'
               | 'persist' IDENT ';'
               | 'copy' IDENT 'to' IDENT ';'
               | 'reshape' IDENT 'into' IDENT ';'
               | 'draw_text' IDENT STRING_LIT 'at' expr 'font' STRING_LIT 'size' expr 'color' expr ('bold')? ('center')? ';'
               | 'fill' IDENT 'with' 'color' COLOR_LIT ('radius' expr)? ('shadow' expr)? ';'
               | 'compose' ('vertical' | 'horizontal' | 'grid') 'on' IDENT ':' composition_rows 'end'

composition_rows ::= composition_row (';' composition_row)*
composition_row ::= IDENT 'at' 'x:' expr ',' 'y:' expr ('weight' expr)?

expr         ::= logical_expr

logical_expr ::= comparison_expr (('and' | 'or') comparison_expr)*

comparison_expr ::= additive_expr (('==' | '!=' | '<' | '>' | '<=' | '>=' | '≈' 'within'? FLOAT_LIT?) additive_expr)?

additive_expr ::= multiplicative_expr (('+' | '-') multiplicative_expr)*
multiplicative_expr ::= unary_expr (('*' | '/' | '%' | '×') unary_expr)*
unary_expr   ::= ('-' | 'not')? primary_expr

primary_expr ::= INT_LIT | FLOAT_LIT | COLOR_LIT | STRING_LIT | BOOL_LIT
               | IDENT | IDENT '[' axis_index (',' axis_index)* ']'
               | IDENT '.' COMPONENT | '(' expr ')'
               | 'create' 'region' '[' dim_spec (',' dim_spec)* ']' 'of' element_format ('@' tier)?
               | '|' expr '|'
               | '[' expr (',' expr)* ']'

matrix_literal ::= '[' '[' expr (',' expr)* ']' (',' '[' expr (',' expr)* ']')* ']'

region_slice ::= IDENT '[' axis_slice (',' axis_slice)* ']'
axis_slice   ::= AXIS_IDENT ':' (expr | expr '..' expr | expr '..' | '..' expr | '..' | '*')

predicate    ::= logical_pred
logical_pred ::= comparison_pred (('and' | 'or') comparison_pred)*
comparison_pred ::= additive_pred (('==' | '!=' | '<' | '>' | '<=' | '>=' | '≈') additive_pred)?
additive_pred ::= unary_pred (('+' | '-') unary_pred)*
unary_pred   ::= ('not' | '-')? primary_pred
primary_pred ::= INT_LIT | FLOAT_LIT | BOOL_LIT | IDENT
               | IDENT '[' axis_index (',' axis_index)* ']'
               | IDENT '.' COMPONENT | IDENT '.' IDENT
               | 'forall' '(' IDENT ':' type ')' predicate
               | 'exists' '(' IDENT ':' type ')' predicate
               | '(' predicate ')'

temporal_spec ::= 'temporal' 'invariant' ':' temporal_expr (';' temporal_expr)*
temporal_expr ::= 'always' '(' inner_temporal ')'
               | 'eventually' '(' inner_temporal ')'
               | temporal_expr 'until' temporal_expr
               | temporal_expr 'within' expr ('ms' | 's')
inner_temporal ::= IDENT '.' 'written' | IDENT '.' 'being_written' | IDENT '.' 'being_scanned'
               | inner_temporal '⇒' inner_temporal | inner_temporal 'and' inner_temporal
               | inner_temporal 'or' inner_temporal | 'not' inner_temporal
               | 'every' 'process' 'is' 'eventually' 'activated' | '(' inner_temporal ')'

type         ::= 'u8' | 'u16' | 'u32' | 'u64' | 'i8' | 'i16' | 'i32' | 'i64'
               | 'f32' | 'f64' | 'bool'
               | region_type | matrix_type | refinement_type

matrix_type  ::= 'matrix' '<' '[' dim_spec (',' dim_spec)* ']' '→' '[' dim_spec (',' dim_spec)* ']'
refinement_type ::= type 'where' predicate
```

---

## 13. Compiler Pipeline

```
┌──────────────────────────────────────────────────────────────────┐
│                       gluon pipeline                             │
├──────────┬──────────┬───────────┬──────────┬──────────┬──────────┤
│  lexer   │  parser  │  resolver │  checker │ verifier │ codegen  │
│  tokens  │  CST→AST │  name res │ type chk │ SMT/TLA  │ WASM    │
├──────────┼──────────┼───────────┼──────────┼──────────┼──────────┤
│ .g src   │  CST     │ resolved  │ typed    │ verified  │ .wasm   │
│          │  (conc.) │  AST      │  AST     │  AST     │  binary │
└──────────┴──────────┴───────────┴──────────┴──────────┴──────────┘
```

**1. Lexer** — Tokenizes UTF-8 source. Unit suffixes are part of number literals.

**2. Parser** — Recursive descent, producing CST with spans.

**3. Name Resolver** — Binds identifiers to declarations. Reports undefined names.

**4. Type Checker** — Shape checking, dimensional analysis, capability checking.

**5. Verifier** — SMT contract verification + temporal model checking.

**6. Code Generator** — Produces WASM binary importing kernel trait functions. Verified contracts are erased (no runtime overhead).

---

## 14. WASM ABI Specification

### 14.1 Imports (from Kernel)

```wat
(import "kernel" "read_region"   (func $read_region  (param i64 i32 i32) (result i32)))
(import "kernel" "write_region"  (func $write_region (param i64 i32 i32) (result i32)))
(import "kernel" "region_info"   (func $region_info  (param i64 i32) (result i32)))
(import "kernel" "subscribe"     (func $subscribe    (param i64 i64 i32) (result i32)))
(import "kernel" "unsubscribe"   (func $unsubscribe  (param i64 i64) (result i32)))
(import "kernel" "grant"         (func $grant        (param i64 i64 i32) (result i32)))
(import "kernel" "revoke"        (func $revoke       (param i64 i64) (result i32)))
(import "kernel" "spawn"         (func $spawn        (param i32) (result i64)))
(import "kernel" "kill"          (func $kill          (param i64) (result i32)))
(import "kernel" "current_pid"   (func $current_pid  (result i64)))
(import "kernel" "create_region" (func $create_region (param i32) (result i64)))
(import "kernel" "destroy_region"(func $destroy_region (param i64) (result i32)))
(import "kernel" "set_tier"     (func $set_tier     (param i64 i32) (result i32)))
(import "kernel" "yield"         (func $yield        ()))
```

### 14.2 Exports

```wat
(func (export "activate") ...)
(memory (export "memory") 1)
```

### 14.3 Process Descriptor (Custom Section)

```
Section "gluon.process":
  label:       "compositor"
  inputs:      [(region_id, access), ...]
  outputs:     [(region_id, access), ...]
  private:     [region_id, ...]
  subscriptions: [region_id, ...]
```

---

## 15. Standard Library Packages

```
stdlib/
├── math.g           -- sin, cos, tan, exp, log, sqrt, abs, min, max, clamp
├── matrix.g         -- identity, translate, scale, rotate, perspective, orthographic,
│                        look_at, transpose, inverse, determinant
├── graphics.g       -- project, blend, rasterize, clear, swap_buffers, draw_text, fill
├── quantum.g        -- evolve, measure, tensor_product, partial_trace
├── neural.g         -- convolve, pool, relu, sigmoid, softmax, batch_norm, matmul
├── signal.g         -- fft, filter, downsample, normalize
├── input.g          -- decode_scancodes, parse_touch, count_active_contacts, gesture_recognizer
├── storage.g        -- compress, decompress, serialize, deserialize, persist, migrate
└── collections.g   -- map, reduce, filter, zip, scan, sort
```

---

## 16. Verification Theorem Catalogue

Built-in theorems verified by the compiler (common contracts need not be reproved):

| Theorem | Statement | Proved by |
|---|---|---|
| `u8_overflow` | `∀ a:u8, b:u8. a*b ≤ 65025` | SMT |
| `region_bounds` | `∀ i:idx, r:region[x: N]. 0 ≤ i < N` | SMT |
| `blend_alpha_preserved` | After `blend src over dst`, `dst.a == 255` if `src.a == 255` or `dst.a == 255` | SMT |
| `matrix_inverse` | `M * M⁻¹ == identity` if `det(M) ≠ 0` | SMT |
| `project_preserves_type` | `project` output has format `U8x4` | type system |
| `evolve_unitary` | `evolve` preserves total probability `≈ 1.0` | SMT |
| `convolve_bounds` | Output = `(input - kernel + 2*padding) / stride + 1` | SMT |
| `softmax_sum` | `sum(softmax(x)) ≈ 1.0` within tolerance | SMT |
| `no_deadlock` | Dataflow graph has no cycles | temporal MC |
| `eventual_response` | `writer.written ⇒ eventually subscriber.written` | temporal MC |
| `no_scan_write_conflict` | Double-buffer invariant | temporal MC |
| `layout_non_overlap` | Children in compose do not overlap | SMT |