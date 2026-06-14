# 0032. Caller-homed specialization for per-module, incremental builds

- Status: Proposed
- Date: 2026-06-14

## Context

The driver consumes a directory of `corefn.json` (one per PureScript module, emitted by
`purs`) and produces one wasm. The stated next goal is a **purs-linked differential rebuild**:
when `purs` recompiles only the modules that changed, the wasm backend should likewise
re-process only those modules (and the dependents a change actually affects), reusing cached
artifacts for the rest. [ADR 0021](0021-streaming-dependency-ordered-wpo.md) already sketches
this under *Future: incremental compilation cache* — the **summary-hash invalidation** baseline:

> A module is a cache hit iff its source is unchanged **and** every dependency summary it used
> is unchanged.

That baseline is sound **only if a module's compiled output is a pure function of
`(its own source, its dependencies' summaries)`** — output may depend *downward* (on
dependencies), never *upward* (on dependents) nor on the whole program. [ADR 0021](0021-streaming-dependency-ordered-wpo.md)
Phase 1 (`localOpt`) and [ADR 0021 b1](0021-streaming-dependency-ordered-wpo.md) (M2b-1,
summary-pruned inline context) made **inlining / dictionary elimination** obey that shape.
**Specialization does not**, and it is the one remaining violation.

### Why specialization breaks the property

`Specialize.specializeProgram` (the static-argument transformation, ADR 0005 / 0027) fires for
a call `f(<lambda>, …)`. The new specialization `f$specN` is **placed in `f`'s *defining*
module**, but the call that drives its creation lives in the *consuming* module. So:

- the **consuming** module's output depends on the callee's body (a *downward* dependency — fine);
- the **defining** module's output depends on which `f$specN`s its *consumers* induced — an
  **upward** dependency on its dependents, and via the shared whole-program pass, on the whole
  program.

Concretely this runs **twice, whole-program**: once pre-inline (`specializeProgram lifted`) and
once post-inline (ADR 0027, `specializeProgram result.done`). A measurement during the M2b-2
spike confirmed the upward coupling is **common, not rare**: in the benchmarks `append`,
`mapFold`, `quicksort`, `bfsSum` all specialize a *library* worker
(`Data.Foldable.go$lift1`, `Data.List.Types.go$lift3`, `Data.Functor.go$lift0`, …) whose
concrete lambda only appears at a *consuming* module's call site after that module inlines its
forwarder (ADR 0027). A per-module pass that only specialized against its own callees dropped
all of these (a real optimization regression), which is why the naive "fold respecialize
per-module" attempt (M2b-2a) was abandoned.

The remaining whole-program steps — lowering's metadata tables (`collectCtors` / `collectLabels`
/ `collectFuncs`), function-level reachability (`reachableFunctions`), and representation
analysis (`assignProgramReps`, ADR 0013) — are **cheap, monotone re-derivations** (graph
unions / a single flow pass, no NbE), so they can re-run every build over the assembled program
without defeating incrementality. Specialization is the only *expensive, output-shaping* pass
with an upward dependency.

## Decision

**Home each specialization in the module whose call site drives it (caller-homed
specialization), and run specialization per module, inside the dependency-ordered loop, against
dependency summaries.**

For a call `f(<lambda>, …)` in module `M` where `f` is a candidate callee (own or from a
dependency summary), create `M.f$specN` — the specialized copy lives in **`M`**, not in `f`'s
defining module. Its body is `f`'s body with the lambda substituted and self-calls rewritten to
`M.f$specN`; `f`'s defining module is untouched. The consuming call becomes `M.f$specN(…)`.

This makes each module's optimized output a pure function of `(M's source, dependency
summaries)`:

- **Pre-inline** specialization moves from one whole-program pass before the loop to a
  per-module pass at the start of each module's `localOpt`.
- **Post-inline** specialization (ADR 0027) moves from the whole-program `specializeProgram
  result.done` after the loop to a per-module pass folded into the loop — now sound, because the
  `where`-worker idiom is intra-module *and* the cross-module library-worker case is handled by
  homing the spec in the consumer (the case that defeated M2b-2a).

### Summary extension

A dependency summary must now also retain the **bodies of specialization callees** it exposes —
functions with a non-empty `staticFnParams` (a function parameter applied in the body and passed
unchanged through recursion). These join the inline candidates and effectful bindings the
summary already keeps ([ADR 0021 b1](0021-streaming-dependency-ordered-wpo.md) / M2b-1,
`DictElim.summarize`). The keep-set is still computed once over the specialized program, so it
stays a bounded, well-defined interface.

### Consequence for the whole-program respecialize barrier

With specialization caller-homed and per-module, `MiddleEnd.runOpt` no longer needs the
post-loop `specializeProgram result.done` + whole-program `finalized` rebuild. Each module is
*fully finalized inside the loop* (specialize → inline → impurify → reduce → respecialize →
reduce), so the loop can yield finalized modules one at a time — the seam the incremental cache
(and, later, level-parallel optimization) writes to.

## Consequences

- **Incremental baseline becomes implementable and sound.** Cache key for a module = hash of its
  `corefn.json` ⊕ the hashes of the dependency summaries it consumed. A dependency change that
  does not alter its summary does not invalidate dependents (the ML-`.cmi` property, ADR 0021).
  The expensive per-module work (specialize + NbE normalize + lower) is skipped on a hit; the
  cheap whole-program glue (reachability, reps, link, Binaryen `-O`) re-runs over the assembled
  program each build.
- **Behaviour-neutral target (acceptance bar).** Output must equal today's modulo (a) `$specN`
  renumbering (per-module fresh-name counters) and (b) the *module* a spec is homed in — both
  invisible after linking into one wasm. Gate: the bench wasm is byte-identical after
  canonicalizing `$specN` (the same gate M2b-1 used), plus e2e/unit green and no benchmark
  regression.
- **Cost: lost cross-consumer dedup.** Two modules that specialize the same callee with the same
  lambda now each home their own copy, where the whole-program pass shared one. Expected rare
  (distinct consumers usually pass distinct lambdas); Binaryen's duplicate-function elimination
  (`-O`) merges identical copies as a backstop. If it proves material, a post-link identical-spec
  merge can be added — but it is not on the incremental critical path.
- **Supersedes** the "run specialization sequentially before the parallel phase, or made
  per-module (caller-homed)" note in [ADR 0021](0021-streaming-dependency-ordered-wpo.md)
  *Future: level-parallel* — this ADR chooses the caller-homed option and makes it the default,
  which is also what unblocks that future parallelism.
- **Refines** [ADR 0027](0027-specialize-after-inlining.md): post-inline specialization stays,
  but per-module and caller-homed rather than whole-program.

## Plan (phased, each independently verifiable against the byte-equal gate)

1. **Caller-homed placement.** Change `Specialize` to home new specs in the consuming module
   (parameterize the spec's owning module by the call site, not `info.modName`). Keep the single
   whole-program `specializeProgram` call for now. Gate: bench byte-equal modulo `$specN`.
2. **Per-module pre-inline specialize** against dependency summaries inside `localOpt`; extend
   `DictElim.summarize` to keep specialization-callee bodies. Remove the pre-loop whole-program
   `specializeProgram`. Gate as above.
3. **Per-module post-inline respecialize** folded into the loop; remove the post-loop
   `specializeProgram result.done` + `finalized` rebuild. `runOpt` yields finalized modules one
   at a time. Gate as above.
4. **Summary-hash incremental cache.** Persist each module's `(summary, optimized MIR)` at the
   discard hook; key by corefn hash ⊕ consumed dependency-summary hashes; reuse on a hit. The
   differential-rebuild driver in `purs-wasm`. (corefn / source hashes are already available via
   spago's `cache-db.json`, ADR 0016.)

Lowering's metadata tables, `reachableFunctions`, and `assignProgramReps` stay whole-program
(cheap re-derivation); caching the *lowered* per-module output is a later refinement, not part of
the sound baseline.

## Alternatives considered

- **Keep callee-homed specialization; capture the upward dependency in the cache key.** A module's
  key would have to include every consumer that homes a spec in it — i.e. its dependents — turning
  the clean leaf-first DAG into a bidirectional invalidation graph. Fragile and against the grain
  of summary-hash invalidation; rejected.
- **Drop cross-module post-inline specialization (accept the regression).** Simplest, but
  measured as a real benchmark regression (the library-worker case above); rejected.
- **Per-module separate wasm + link.** Rejected for the same wasm-GC type-sharing reasons as
  [ADR 0009](0009-build-and-linking-model.md) / [ADR 0021](0021-streaming-dependency-ordered-wpo.md).
