# 0010. The shared runtime as a separate, hand-written wasm module

- Status: Accepted
- Date: 2026-06-01
- See also: [ADR 0012](0012-ulib-curated-package-ffi.md) — splits this single
  runtime module into a runtime *core* plus per-package `ulib` foreign modules
  (which reuse the singleton-type canonicalization established here).

## Context

The backend ships a small **shared runtime** — helper functions that every
generated program may call: `$rt.proj` (record/dictionary label search), `$rt.strEq`
/ `$rt.strConcat` (string equality / concatenation), `$rt.arrayConcat`, the
Euclidean `$rt.intDiv` / `$rt.intMod` / `$rt.intDegree`, and `$rt.showInt`. Today
each of these is **constructed in the compiler's source** (`Codegen.purs`) through
the Binaryen *expression-builder* API: every instruction is one PureScript call
(`B.i32Add mod a b`, `B.arraySet …`), assembled by hand.

This has become the backend's authoring bottleneck:

- It is verbose and error-prone. `$rt.showInt` — a single digit-extraction loop —
  is dozens of `B.localGet` / `B.if_` / `B.block` calls with manual local-slot
  bookkeeping. There is no way to read it as code.
- The next runtime pieces are **large algorithms**: `showNumber` needs a shortest
  round-trip float→decimal renderer (Ryū / Grisu / Dragon4 — hundreds of lines with
  lookup tables); `showString` / `showChar` need the full escaping rules. Writing
  these through the builder API is impractical.
- The runtime cannot be tested in isolation — it only exists as a side effect of
  compiling a program.

We want to author the runtime **as ordinary code** (readable, independently
testable) while keeping the **single self-contained wasm** output of ADR 0002 /
0009. Two questions had to be answered before committing:

1. **What language?** The obvious candidate, AssemblyScript, **does not fit**: it
   compiles to *linear memory* with its own managed heap (its `string` is a
   linear-memory UTF-16 object), whereas our value substrate (ADR 0001) is *wasm
   GC* — `$Str = (struct (ref $Bytes))`, `$Vals = (array eqref)`, `$Int =
   (struct i32)`, eqref boxing. An AssemblyScript helper cannot take or return our
   GC values; bridging would mean marshalling between two heaps. Any helper that
   touches our values must therefore be authored against our exact GC types, which
   in practice means **hand-written WAT**. (AssemblyScript remains an option only
   for *pure-scalar* algorithms — e.g. a Ryū core that emits ASCII digits into
   linear memory, with thin WAT glue copying them into a `$Bytes` — a tradeoff to
   weigh when `showNumber` is implemented; it is out of scope here.)

2. **How does generated code reach the runtime, without losing the single-file
   output and without a cross-module GC-type-identity problem?** The decisive
   observation is that our calling convention (ADR 0004) is already **uniformly
   `eqref` / `i32` / `f64`**: every `$rt.*` signature is in those abstract types
   (`$rt.strConcat : (eqref, eqref) -> eqref`, `$rt.showInt : (i32) -> eqref`, …).
   The concrete GC types appear *only inside* the helper bodies. So the import
   boundary carries no concrete struct types at all.

## Decision

Author the shared runtime as a hand-written **`runtime/runtime.wat`** that declares
the value rec-type group (identical to `buildRuntimeTypes`) and defines + exports
every `$rt.*` helper. Assemble it once to `runtime.wasm` with Binaryen's bundled
`wasm-as`.

Generated modules **import** the `$rt.*` functions (from module `"rt"`) instead of
building them inline. The import boundary uses only `eqref` / `i32` / `f64`, so it
declares no shared concrete types. There are two consumer paths, by use:

- **In-process (tests, the in-memory API):** instantiate `runtime.wasm` first, then
  instantiate the generated module with `{ rt: runtimeInstance.exports }`. No
  external tool needed.
- **Build artifact (`bin`, production):** `wasm-merge generated.wasm runtime.wasm`
  → one self-contained `.wasm` with the runtime merged in and imports resolved,
  preserving ADR 0002.

`buildRuntimeTypes` stays in the compiler unchanged: the generated module still
declares its own copy of the rec group for its own `struct.new` / `array.new`. The
runtime module declares the structurally identical group for its helper bodies.

### Why this is safe (validated by spike, 2026-06-01)

Although import *signatures* are abstract, the `eqref` *values* crossing the
boundary carry concrete types (a `$Str` made by the generated module), and a helper
downcasts them (`ref.cast (ref $Str)` against the *runtime's* `$Str`). This requires
the two modules' `$Str` to canonicalize to the **same** type. A minimal two-module
spike confirmed it does in V8 / Node 22:

- App module builds a `$Str` with *its* type, passes it as `eqref` to an imported
  helper in the runtime module, which casts to *its* `$Str` and reads the length →
  correct result (no `illegal cast`).
- The identity **survives `wasm-opt -O3`** applied to either or both modules
  independently, and the **`wasm-merge` single-file** output instantiates with no
  imports and runs correctly.

The requirement this imposes: `runtime.wat`'s rec group must remain **structurally
identical** (same members, order, field types/mutability) to `buildRuntimeTypes` —
two sources of truth for a deliberately stable group (ADR 0001). A mismatch surfaces
immediately as an `illegal cast` in the existing E2E suite.

## Consequences

- `Codegen.purs` loses all `add*Helper` functions and the helper-name plumbing; the
  runtime becomes readable WAT that can be `wasm-dis`'d, unit-tested, and grown.
- Large future helpers (`showNumber`, `showString`/`showChar`, `showArray`) are
  written in WAT (or, for a pure-scalar core, optionally AssemblyScript with
  marshalling) rather than the builder API.
- A new build input: `runtime.wat` → `runtime.wasm` (assembled by the bundled
  `wasm-as`; the artifact is produced by a build step). The test harness loads it;
  `bin` runs `wasm-merge` as a post-step.
- The rec group is now declared twice (compiler `TypeBuilder` + `runtime.wat`) and
  must be kept in lockstep. Mitigated by its stability and by E2E `illegal cast`
  detection; a future step could derive one from the other.
- Optimization order for `bin`: optimize **after** merging (one module), so the
  optimizer never has to preserve identity across a boundary — though the spike
  shows it does anyway.

## Alternatives considered

- **Keep building helpers via the Binaryen API, but consolidate into one
  `Codegen.Runtime` module.** Cheapest; fixes only the "scattered" complaint, not
  the authoring cost, and does nothing for the big upcoming algorithms. Rejected as
  insufficient for where the runtime is heading.
- **Two-module distribution (no merge).** Ship `runtime.wasm` + `app.wasm` and let
  the host wire them at instantiation. Simplest packaging, but abandons the
  single-file output of ADR 0002. Kept only as the in-process *test* path, not the
  artifact path.
- **AssemblyScript for the whole runtime.** Incompatible substrate (linear memory
  vs wasm GC), as above. Rejected for any helper that touches our values.
- **Parse `runtime.wat` and splice its functions into the generated module
  in-process** (one module, no merge, no import boundary). Avoids the merge step,
  but needs reliable retrieval of named GC heap types from a parsed Binaryen module
  to reuse for generated code — an API we have not validated. The import boundary
  sidesteps the problem entirely. Revisit if the merge step proves costly.

## References

- ADR 0001 — value representation (the GC rec-type group the runtime shares).
- ADR 0002 — FFI / runtime strategy and the single self-contained wasm goal.
- ADR 0004 — uniform `eqref` calling convention (why the import boundary is
  type-clean).
- ADR 0009 — build & linking model (`bin`, multi-module input → single wasm).
- Binaryen tools used: `wasm-as`, `wasm-merge`, `wasm-opt`, `wasm-dis` (bundled).
