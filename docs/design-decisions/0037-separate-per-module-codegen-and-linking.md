# 0037. Separate per-module codegen and linking (per-module wasm + `wasm-merge`)

- Status: Accepted; **implemented** (2026-06-18) — Phases 0–2 + the Phase-3 codegen restructure are
  in, i.e. single-module compilation behind `--per-module-codegen`, verified at behaviour + export/size
  parity with the whole-program build. Still pending: the per-module **wasm cache** (incremental
  rebuilds) and the cross-module-unboxing recovery (Addendum).
- Date: 2026-06-17 (implemented 2026-06-18)

## Context

Building a large program is slow. Self-compiling the `purs-wasm` CLI (324 reachable
modules → an 8 MB wasm) takes ~45 min. Measured breakdown:

- module select + decode: ~35 s;
- per-module **optimization** (DictElim/NbE/Specialize/…): ~10–15 min cold, but
  **already cached** — the `.pmi`/`.pmo` cache (ADR 0034) serves it in ~25 s on a warm
  rebuild;
- **lower + codegen (`buildModule`)**: **~30 min, and it re-runs whole-program on every
  build** — never cached;
- Binaryen `-O` + validate + `wasm-merge`: the remainder.

Profiling the 30-min `buildModule`: ~73 % is inside `binaryen.js` (the Emscripten-compiled
Binaryen, one FFI call per IR node) and ~27 % GC; the PureScript side is spread thin (no
single quadratic — `reachableFunctions` is a clean BFS, `assignProgramReps` a bounded
fixpoint). The cost is the *volume* of whole-program codegen, which the `.pmo` cache does
not touch (it caches optimized MIR, not emitted wasm).

So the path to fast **incremental** rebuilds (the dev-iteration case; a cold 8 MB build
cannot be ~seconds while we build the module node-by-node through `binaryen.js`) is to make
**codegen per-module and cacheable**: emit each module's wasm once, reuse it when the module
is unchanged, and `wasm-merge` the set — extending the cache from "optimized MIR" to
"emitted wasm". This is the "batch compiler" shape that ADR 0009 (single-wasm output) and
ADR 0021 (which keeps "one Binaryen module, populated incrementally") deliberately avoided,
because for wasm-GC it means **sharing GC struct types across separately-built modules** and
**turning every cross-module call into an import/export boundary** — judged too hard at the
time.

Three throwaway spikes (hand-written `.wat`, assembled with `wasm-as`, linked with
`wasm-merge --all-features`, run on Node 24) re-tested those fears against Binaryen 123 and
found them solvable:

1. **GC type sharing (①).** A struct value built in module A is read in module B after merge
   — `wasm-merge` **canonicalises structurally-identical types**, including subtyped and
   recursive (`$Data` base + `$Cons` subtype) shapes. Constraint: wasm-GC is *isorecursive*,
   so identity is per **rec group** — a type grouped with different neighbours stays a
   distinct type (a cross-module `ref.cast` then traps). Mitigation: emit each type as its
   **own singleton rec group**; singletons canonicalise regardless of a module's other types.
   This is directly applicable because our codegen types ADT fields as `i32`/`f64`/`eqref`,
   never a specific subtype, so the GC type graph **has no mutual-recursion cycles** — every
   type is a base or a base-subtype and can be a singleton.
2. **Cross-module calls + closures (②).** A closure created in module A (a `funcref` to A's
   lifted body + a captured env) is applied in module B via the **shared runtime
   `applyClo`/`call_ref $Code`** after merge — the `funcref` survives the merge and dispatches
   correctly. Cross-module calls become import/export pairs that `wasm-merge` resolves, the
   same mechanism already used for the runtime and foreign providers. The closure ABI was
   already engineered for this (`$Clo` holds a generic `funcref`, not `(ref $Code)`, keeping
   `$Code` out of `$Clo`'s rec group — RuntimeTypes.purs).
3. **Representation ABI (③).** Today `Lower.Unbox.assignProgramReps` is a **whole-program**
   fixpoint: a parameter's unboxed rep is the join over *every* call site (sound only if all
   callers agree, since unboxing a non-`$Int` `eqref` traps). This was an opportunistic
   optimisation enabled by ADR 0009's whole-program availability — an earlier *local* version
   (the U2-era `assignReps`) existed and worked; U3 made it whole-program to also unbox
   function parameters/results across calls (so a tail loop runs entirely in `i32`). It was
   **not** chosen because per-module was impossible.

## Decision

Adopt **separate per-module compilation to wasm, linked by `wasm-merge`** (the model Grain
uses: each source file → an object file holding *signature + lowered IR*, then a link/merge
step; Grain likewise codegens via Binaryen). Concretely:

- **Module-boundary ABI is fixed boxed (`eqref`).** Exported/imported functions take and
  return boxed values. The representation (unbox) analysis becomes **module-local**: it keeps
  the U3 fixpoint *within* a module (so intra-module tail loops still run unboxed — the main
  performance driver) but pins cross-module-visible parameters/results to `Boxed`. We
  therefore **lose only the cross-module increment U3 added over U2**, not intra-module
  unboxing. A worker/wrapper split can later recover the loop of an *exported* recursive
  function if measurement ever warrants it.
- **The lowered ANF stays representation-free at module boundaries** so it is a stable,
  cacheable per-module artifact: `.pmi` carries the interface (export signatures, the
  deterministic type/label ids), `.pmo` carries the per-module **lowered ANF** (the
  codegen input), and codegen emits per-module wasm — `wasm-merge` links them with the
  runtime and foreign providers into the single wasm ADR 0009 still mandates as the *output*.
- **GC types are emitted as singleton rec groups**, deterministically from the field-rep
  signature, so each module's copy canonicalises under merge.
- **Cross-module calls are import/export pairs**; closures dispatch through the shared runtime.

This is staged so each step is independently verifiable against the current whole-program
output before the build is actually split:

- **Phase 0 — groundwork (behaviour-neutral on the current build):** emit data types as
  singleton rec groups; assign record-label / intern ids by a **deterministic global scheme**
  (so per-module emission agrees without a whole-program pass — barrier ④).
- **Phase 1 — module-local representation:** restrict `assignProgramReps` to the boxed
  boundary (behind a flag; A/B against the suite + bench).
- **Phase 2 — per-module codegen:** per-module lower → ANF in `.pmo`; per-module codegen →
  per-module wasm; `wasm-merge` link; cross-module CAF-init ordering at link time (barrier ⑤,
  partly designed in ADR 0021's link/emit split); whole-program DCE deferred to Binaryen's
  merge-time DCE (barrier ⑥).
- **Phase 3 — per-module wasm cache:** reuse unchanged modules' wasm; re-emit only changed
  modules; incremental rebuild → ~seconds.

## Consequences

- **Incremental rebuilds approach ~seconds** (re-emit the changed modules + merge); a cold
  build stays codegen-bound (this does not by itself make the first build fast).
- **Lose cross-module unboxing — measured worst case ~2.6×.** The existing bench corpus
  cannot measure this (the `fib`/`sumLoop`/… benches live in one `Bench.Main` module and
  cross a boundary only a handful of times per run — their hot loops are intra-module, so the
  boxed-boundary simulation never touches them; it only confirmed intra-module unboxing is
  preserved). A dedicated microbenchmark (`Bench.Main.crossModule`: a tight intra-module loop
  whose every iteration calls `Bench.Helper.step`, a **self-recursive — so never inlined —
  O(1)** `Int → Int`) measured the per-crossing cost directly: `crossModule(20M)` ran in
  **~34 ms unboxed vs ~87 ms with the boundary pinned to boxed (~2.6×)**, i.e. **~2.6 ns per
  crossing** (one `$Int` alloc + unbox). This is the **worst case** — a trivial callee crossed
  every iteration, where boxing dominates the ~1.75 ns iteration. The penalty scales as
  `~2.6 ns / (callee work + iteration)`, so it shrinks toward negligible as the callee does
  real work, and it only applies where a hot scalar cross-module call **survives inlining**
  (cheap functions inline away; the per-module model keeps cross-module inlining via summaries
  — dict-elim / general inline / caller-homed specialization). The residual hot case (an
  *exported, recursive, scalar* function) can be recovered later with a worker/wrapper split.
  How often real programs hit the un-recovered case is the open question; for the self-compile
  and the bench corpus it appears rare, but that is not yet quantified.
- **Cache coupling stays minimal.** Because the boundary ABI is fixed (no reps in the
  interface), a module's `.pmi` does not carry representation decisions, so a dependency's
  internal rep change does not invalidate dependents.
- **New required work:** deterministic label/intern ids (④), link-time CAF-init ordering (⑤),
  merge-time DCE (⑥).
- **Relationship to prior records.** ADR 0009's *single-wasm output* is preserved — the merge
  produces one module; we compile per-module *internally*. This **revisits ADR 0021's
  rejected "per-module separate wasm + link" alternative** with the spike evidence above, and
  *builds on* ADR 0021's per-module optimisation + summaries and ADR 0032/0034's caches rather
  than replacing them.

## Alternatives considered

- **Keep whole-program codegen, shrink the constant** (cut the 27 % GC / per-node `Effect`
  and array allocation, thin the Binaryen FFI). Helps every build ~1.5–2×, but is bounded and
  never reaches ~seconds; orthogonal and can still be done.
- **Parallelise codegen across worker threads** (each its own `binaryen.js`, then merge).
  Speeds the *cold* build up to ~#cores×, but does nothing for incremental and adds
  per-worker Binaryen memory + coordination. A possible later addition, not the incremental win.
- **Carry representations in `.pmi` to keep cross-module unboxing.** Recovers the U3
  increment, but: parameter reps flow caller→callee while compilation flows callee→caller, so
  it needs either a link-time fixpoint over the interface reps (a whole-program step, not
  purely incremental) or a heuristic commit (residual boxing where it misses the join); and it
  reintroduces rep-driven cache coupling. Rejected for now because the measured boxed-boundary
  cost is small; revisit (result reps first — they flow naturally callee→caller) only if a
  real workload shows a hot cross-module numeric path regressing.
- **Cache the lowered ANF only, keeping whole-program codegen.** Skips lowering on a hit, but
  lowering is not the ~30-min bottleneck (codegen is), so the win is small; the ANF cache is
  worthwhile only as the per-module codegen *input* (Phase 2), not on its own.

## Addendum (2026-06-18): the cross-module-unboxing recovery path

The Decision fixes the module boundary to boxed and the "Carry representations in `.pmi`"
alternative above was rejected *for now*. This addendum records the staged ladder for
recovering cross-module unboxing later, should a real workload need it, and the one
structural fact that orders that ladder. It changes no decision — the boxed boundary stands;
this is the map for if/when we revisit it.

**The organizing fact — representation flows in two directions, asymmetrically.** The rep
analysis (`Lower.Unbox.assignProgramReps`) infers a result rep and parameter reps with
*opposite* data-flow:

- a **result** rep is fixed by the function's own body (the join of the atoms it returns) —
  it flows callee → caller, the *same* direction as separate compilation (a module compiles
  against its dependencies' interfaces);
- a **parameter** rep is the join over *every* call site's argument type — it flows
  caller → callee, *against* compilation.

Unboxing a parameter is sound only if every caller passes that scalar (a boxed `eqref` fed to
an `i32` parameter traps at the cast), which a separately-compiled callee cannot prove. So:

> **Result reps are publishable in `.pmi` today, soundly and without a link-time fixpoint.
> Parameter reps are inherently whole-program or speculative.** This asymmetry — not the menu
> of techniques — sets the priority order.

**The recovery ladder (cost-ascending).** Each rung spends some of the incrementality the
boxed boundary buys (whose virtue is precisely that `.pmi` carries *no* rep decisions, so a
dependency's internal rep change never invalidates its dependents); take a rung only when a
measurement demands it.

1. **Boxed boundary** — the current decision. No rep in the interface; maximal incrementality.
2. **Result reps in `.pmi`** — sound (callee→caller), no fixpoint, smallest change; recovers
   the unboxed-result half. Reach for this first if a cross-module scalar path regresses.
3. **Worker/wrapper for an exported recursive function** — the external entry goes through the
   boxed wrapper, the self-recursion through an unboxed worker, so the function's *own loop*
   runs unboxed. This recovers an *exported recursive scalar* function's loop; it does **not**
   by itself recover a hot caller in module B calling a small cross-module leaf in A (B can
   only call A's boxed wrapper — to call the unboxed worker, the worker's signature must be
   published, i.e. rung 4). Worker/wrapper is the safe container; published reps are what fill
   it for external callers.
4. **Parameter reps in `.pmi` (full interface-rep ABI)** — recovers the unboxed-parameter half,
   but requires either a link-time fixpoint over the interface reps (a whole-program step, not
   purely incremental) or a speculative commit with residual boxing where the join is unknown,
   and it makes the rep part of cache invalidation. Only if a measured hot cross-module
   *parameter* path still regresses after rungs 2–3.
5. **Link-time specialization (ThinLTO-style cloning)** — emit specialized variants and select
   at link. Note this is *not* the cheap "rewrite imports/exports, no relowering" that link-time
   symbol resolution suggests: `wasm-merge` does not rewrite representations, so unboxing a
   cross-module call at link time needs the unboxed variant present on both sides — i.e. it is
   cloning/specialization, not mere call rewriting. Research-grade; last.

**Two clarifications on the performance model.** (a) Cross-module *inlining* survives the
per-module model (via the summaries — dict-elim, general inline, caller-homed specialization),
so a small leaf is inlined away and its boundary disappears; the boxed-boundary cost applies
only to a call that *survives inlining* and is hot and scalar — rare, and inlining is the first
line of defense before any rep-ABI scheme. (b) The inter-module *wasm* boundary (this ADR) is
distinct from the *foreign* (JS) boundary: a benchmark like `mapFoldArray` is slow at the
foreign boundary (ADR 0026 / WasmBase territory), which the boxed *module* ABI does not touch.
