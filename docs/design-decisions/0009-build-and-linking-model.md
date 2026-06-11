# 0009. Build and linking model: multi-module input, single-wasm output

- Status: Accepted
- Date: 2026-06-01

> **Update (2026-06-12):** the build driver named `bin` throughout this record is **retired** —
> reimplemented as the `purs-wasm` package (user `build`) plus a separate maintainer `ulib-tooling`
> package (ADR 0031). The multi-module-input → single-wasm linking model decided here is unchanged;
> read `bin` as `purs-wasm`.

## Context

Until now the backend lowers a **single** CoreFn module to one wasm module — the
shape of the early slices and of the "Prelude-only to a single wasm" milestone.
Real programs (and the real `Prelude`) span many modules, so the build/link model
has to be decided.

Two concerns are easy to conflate but are **separable**:

1. **Input / linking** — consuming and combining the many PureScript modules a
   program is made of (the project's modules plus their dependencies, including
   `Prelude`). Needed regardless of output shape.
2. **Output granularity** — emitting one bundled wasm vs. many wasm modules wired
   together by the host.

Wasm-GC specifics constrain (2). The GC MVP has **no type imports**: sharing
`$Vals`/`$Clo`/`$Code`/`$Str`/… across separately-emitted modules relies on the
engine's **structural (isorecursive) canonicalization** of *identical* recursion
groups, and Binaryen prunes unused types — which can make two modules' groups
diverge and so stop canonicalizing as equal. Closures and dictionaries cross a
module boundary (via `call_ref`) only when those groups canonicalize. (This
differs from `wasm_of_ocaml`, whose multi-module model rests on a shared *linear
memory* import, not GC type identity — so that experience does not transfer
directly.)

Meanwhile the performance lever — type-class **dictionary elimination** (ADR 0005)
along with DCE and inlining — is whole-program in nature (instances are imported
from other modules) and is easiest within a single module.

## Decision

**Multi-module input, single-wasm output.** The compiler reads the compiled
`output/<Module>/corefn.json` of every module reachable from the entry/exports,
combines them, and emits **one** wasm module.

- **Link by module-qualified name.** Top-level names are already `Module.ident`
  (`funcName`, `RCallKnown`), so cross-module calls are ordinary direct `call`s
  within the single module. "Linking" is: load the needed modules, order them by
  import dependency, build the **combined** symbol tables (`knownFuncs` / `ctors`
  / `dictCtors` / `labelIds`) across all modules, and lower every module's decls
  into one `Program`. No relocations or symbol fix-ups beyond that.

- **CoreFn-only for linking.** Everything linking needs is in CoreFn (qualified
  names, arities via `peelAbs`, instance records, accessor functions, calls).
  `externs` is reserved for the optimization phase (dictionary
  specialization/elimination — ADR 0005 / 0007), not required to link.

- **Reachability DCE.** Mark the entry/exported functions as roots and keep only
  reachable functions, leaning on Binaryen's DCE (`optimize()`) and/or an explicit
  reachability pass, so pulling in `Prelude` does not bloat the output.

- **Real `Prelude` is a separate phase**, not part of the linking *mechanism*. It
  carries its own surface: expanding ADR 0002's intrinsics table to `Prelude`'s
  closed foreign set; confirming cyclic instance groups terminate (ADR 0008);
  and bundled runtime helpers (e.g. `showInt`). It is lit up incrementally
  (arithmetic → `Eq`/`Ord` → `Show` → …) on top of a linking mechanism first
  proven with a small dependency-free multi-module example.

- **A `bin` CLI drives the build**: a project's `output/` (plus an entry/roots)
  → one `.wasm` (plus an optional JS loader). It is both the usable artifact and
  the build step the benchmark harness invokes.

- **Multi-wasm output is deferred, not rejected.** A future option is a shared
  **runtime** wasm (a fixed canonical type group + the `$rt` helpers + tier-2/3
  intrinsics) plus one wasm per module, wired by **function imports**, with the
  canonical type group emitted identically in every module (pruning suppressed)
  so it canonicalizes. Its payoff — caching, incremental rebuilds, lazy loading,
  sharing a large stable `Prelude` — grows once the `Prelude` is real and large,
  and it trades away whole-program optimization, so it is sequenced after the
  optimization IR.

## Consequences

- The simplest path to running real, multi-module programs, and whole-program
  optimization (ADR 0005) stays available because everything is in one module.
- The single wasm can grow large for big dependency sets; reachability DCE
  mitigates this, and multi-wasm output remains the escape hatch later.
- Requires a module loader/orderer and a combined lowering entry (a `lowerProgram`
  over many modules) — modest work, since names are already qualified.
- Subsumes the "Prelude-only to a single wasm" milestone: it becomes one instance
  of multi-module-input → single-wasm-output.
- The `bin` CLI makes the project usable and unblocks the benchmark harness, which
  in turn drives the optimization roadmap by data rather than guesswork.

## Alternatives considered

- **Multi-wasm output now** (per-module wasm + shared runtime). Rejected for now:
  Wasm-GC type-canonicalization fragility (no type imports; Binaryen pruning can
  diverge the shared rec groups), the import-wiring/host-orchestration cost, and
  it blocks cross-module whole-program optimization. Deferred (see Decision).
- **Emit per-module wasm and bundle at the JS level.** A JS bundler cannot create
  GC type identity across modules, so the canonicalization problem remains; no
  real benefit over emitting one wasm directly.
- **Stay single-module-input.** Cannot express real programs or the real
  `Prelude`. Rejected.

## References

- ADR 0001 — Wasm GC substrate / value representation (the shared type group).
- ADR 0002 — FFI via a code-generator intrinsics table (the `Prelude` foreign
  surface to expand).
- ADR 0005 — high-level optimization IR / dictionary elimination (whole-program;
  the reason single-module output is favoured).
- ADR 0008 — constructing recursive dictionary groups (must hold for real
  `Prelude` instance groups).
