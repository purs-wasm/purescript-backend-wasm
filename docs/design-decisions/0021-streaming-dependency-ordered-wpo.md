# 0021. Streaming, dependency-ordered whole-program optimization

- Status: Proposed
- Date: 2026-06-05

## Context

The driver (`bin` + `MiddleEnd.optimizeProgram` + `Compiler` + `Codegen`) currently:

1. decodes **every** reachable `corefn.json` into memory at once;
2. runs `optimizeProgram` as a **whole-program, N-round fixed point**: translate all →
   lambda-lift all → repeat `{ specialize ; dict-elim + NbE simplify ; impurify }` over
   *all* modules together, rebuilding the inline context from the whole program each round
   (`maxRounds = 8`);
3. lowers the whole program and builds **one** Binaryen module.

Compiling a first real application — `examples/metatheory`, a ~330-line typechecker over
`transformers` / `ordered-collections` / `fmt` — exposed that this does not scale, in two
distinct ways:

- **Memory.** The bin decoded all 476 output modules before any pruning (file-level
  reachability pruning, an interim fix, cut this to 126). Even so, every module's decoded
  AST and MIR is resident at once.
- **Compounding (the dominant failure).** The optimizer **OOMs even at a 10 GB heap**
  (peak 11.6 GB). Instrumenting the per-round program size showed it **~doubles every
  round** (37k → 80k → … nodes) and never converges. It is **not** any single inline rule
  (disabling specialization, `smallLambda` let-inlining, or filtering cyclic inline
  candidates each changed nothing): it is the **N-round whole-program re-optimization
  re-inlining an already-optimized program** — NbE simplify is not idempotent across rounds
  on transformer dictionary chains (`monadStateT(monadExceptT).Applicative0(…).Apply0(…).
  Functor0(…).map`, huge and re-expanded each round). `maxRounds = 1` completes.

A first attempt to fix this at the inliner level (ADR 0020 stage 3, *contextual*
reduction-aware inlining: inline a top-level binding only when consumed in a reducing
position) **regressed the benchmarks ~2×** (it skips beneficial bare-value inlines) and did
**not** fix the compounding (which is the round structure, not the inline policy). It was
reverted. The conclusion: the whole-program-in-memory + global-N-round-fixpoint shape is
itself the problem, and the fix is architectural.

## Decision

**Compile in dependency (topological, leaf-first) order, optimizing each module once
against the finalized summaries of its dependencies, emitting its code incrementally into a
single Binaryen module, and retaining downstream only a per-module summary.**

This is the standard batch-compiler structure adapted to whole-program optimization. Its
correctness rests on one fact:

> **For an acyclic module-dependency graph, optimizing each module once (to local
> saturation) in topological order — with each module seeing the already-finalized,
> optimized form of its dependencies — is equivalent to the whole-program fixed point.**

A dependency is finalized before its dependents, and a dependent never feeds back into a
dependency (no cyclic imports in PureScript), so a single dependency-ordered pass reaches
the same result the global N-round fixpoint was inefficiently re-deriving — without
re-optimizing finalized modules, which is what compounded.

### The per-module summary (= the whole-program "interface")

For each module, the only thing downstream modules need is its **summary**:

- the **optimized IR bodies of its inline candidates** (dictionary constructors / method
  accessors / instances, small or single-use functions, newtype constructors), and
- its contribution to the **global tables**: rigid data constructors, transparent
  (newtype / dict) constructors, plain-record instance fields, foreign signatures, and the
  purity set (effectful-to-run keys).

A module's **non-candidate bindings** (large functions) are compiled, emitted, and then
**discarded** — nothing downstream inlines them. Memory for optimization is bounded to
"one module's transient MIR + the accumulated summaries + the global tables".

Dependencies are computed from the **actual references** a module makes (`references`, which
in CoreFn already name the *defining* module, canonical), **not** from the coarser `imports`
list. This resolves re-export indirection precisely (a change to a re-exporting module that
does not change the re-exported binding does not spuriously invalidate users), and is what
the summary graph is built from anyway.

### Codegen: one Binaryen module, populated incrementally (b1)

There is a **single** Binaryen module (single-wasm output is retained — ADR 0009; we do
**not** emit per-module wasm and link, which would reintroduce cross-module wasm-GC type
sharing and cross-module-call boundaries that ADR 0009 deliberately avoids). As each
PureScript module is optimized, its functions are **added** to that one module and its MIR
discarded. Whole-program codegen state — record-label → id assignment, the string-intern
table / `$internStr` resolver, mutable globals, runtime imports — is **accumulated across
modules and finalized once** at the end.

Phased, so each step is verifiable:

1. **Dependency-ordered optimization** first (kills the compounding), with codegen still
   taking the whole accumulated optimized program (one `buildModule` call). Bounds the
   *optimizer's* working set; memory still holds all optimized MIR for codegen.
2. **Incremental codegen (b1)** second: refactor codegen to accumulate global state and add
   functions per module, discarding MIR as we go. Bounds total memory to ≈ the output.

### DCE

Function-level dead-code elimination needs reachability from the entry **roots**, which sit
at the *top* of the topological order (processed last) — the opposite end from leaf-first
emission. Resolve with a **cheap binding-level reachability pre-pass** over the reference
graph (from the roots) to compute the live set, then optimize and emit only live bindings.
Binaryen's own DCE (`B.optimize`) remains a backstop for anything that slips through.

### The discard hook

The point where a module's MIR is discarded is a single hook with three roles: (1) discard
(now), (2) **dump the optimized MIR as a build artifact** for inspection (cheap — the
`printModule` text; complements `dump-mir`/`dump-opt`/`dump-prune`/`--trace-mir`), and (3)
write the cache entry (future, below). The architecture must keep the **summary** and the
**per-module optimized output** cleanly separable so (2)/(3) can attach without disturbing
the pipeline.

## Consequences

- **Memory bounded** and **no cross-round compounding** — the two metatheory failures.
- **Behaviour-neutral target**: the dependency-ordered result must equal today's output
  (topo-order ≡ global fixpoint), so e2e/unit stay green and the benchmarks do not regress.
  This is the acceptance bar.
- **Per-module local optimization must itself terminate and not balloon.** The compounding
  was cross-round; a single pass over all modules grows only modestly, so per-module
  optimization to a *bounded* number of local passes is the safe form. The deeper question —
  *why is re-optimization non-idempotent?* — is worth resolving (ideally NbE reaches a fixed
  point in 1–2 local passes so saturation is cheap); a bounded pass count guards termination
  regardless.
- The interim **file-level reachability pruning** in the bin (`corefnImportsImpl` /
  `reachableClosure`) is subsumed by the binding-level reachability pre-pass + streaming
  decode.
- Orthogonal gap, not addressed here: lowering rejects non-scalar literal binders
  (`UnsupportedBinder "only scalar literal binders are supported"`), which metatheory also
  hits; fixed separately.

## Future: incremental compilation cache

Persisting each module's summary + optimized MIR at the discard hook enables a differential
(re)build — recompile only changed modules and the dependents a change actually affects.
Under whole-program optimization the cache key cannot be a module's own source hash alone,
because cross-module inlining makes a dependent's output depend on its dependencies'
*implementations*. Design, in two steps:

1. **Summary-hash invalidation (sound baseline).** A module is a cache hit iff its source is
   unchanged **and** every dependency summary it used is unchanged. The *summary* is the
   whole-program analogue of an ML-style interface (`.cmi`): a change to a dependency that
   does not alter its summary (e.g. the internals of a non-inlined function) does **not**
   invalidate dependents — the ReScript/OCaml "interface unchanged ⇒ no recompile" property,
   correctly generalized. Its limit is intrinsic to inlining: an inline candidate's *body*
   is part of the summary, so changing it does invalidate users. Cache lifetime therefore
   tracks summary stability — a real **optimization-vs-incrementality knob** (a smaller
   inline set ⇒ more stable summaries ⇒ longer-lived cache).

2. **Per-binding access-trace invalidation (precise refinement).** Record, while optimizing a
   module, the exact set of external bindings it used and *which aspect* of each: the **body
   hash** for ones it inlined, the **interface hash** (arity / calling convention) for ones
   it only called, nothing for ones it never touched. A dependent is invalidated only when an
   aspect it actually used changed. Transitivity falls out: an inlined body is the
   dependency's *optimized* body, whose hash already reflects anything *it* inlined, so
   leaf-first recompilation + recorded hashes cascade precisely. **Soundness condition:** the
   trace must capture *every* optimizer-relevant aspect a module depended on — not just
   body-vs-interface, but purity (effect ordering), constructor classification (case
   reduction), newtype transparency, etc. Missing one yields a stale (incorrect) cache, so
   this is the precise-but-risky end state; the summary-hash baseline is sound by
   construction. Module source hashes come from spago's `cache-db.json` (already read, ADR
   0016).

## Future: level-parallel optimization

The topological order partitions into **levels** (antichains) of mutually-independent
modules; a module depends only on lower levels. Because per-module optimization is a **pure
function** of `(module MIR, dependency summaries)` with no shared mutable state (summaries
are read-only; the fresh-name counters are call-local), modules within a level — or, more
generally, any module whose dependencies are all finalized (a work-stealing schedule) — can
be **optimized concurrently**, cutting compile time on wide module graphs (the common case
for PureScript). Only the **optimization** phase parallelizes; **codegen stays sequential**
(the single Binaryen module and its global label/string tables are shared mutable state), so
the shape is *parallel-optimize a level → collect → sequential b1 codegen*.

Cost: Node `worker_threads`/`child_process` plus **serialization of MIR + summaries** across
workers — which is the *same* serializer the incremental cache needs (worker transfer ≡
on-disk cache entry), so the two share machinery. Specialization (currently whole-program,
once) is run sequentially before the parallel phase, or made per-module (caller-homed). This
is enabled by the design but **deferred** — it is a compile-time optimization, below
correctness and the b1 memory work in priority.

## Alternatives considered

- **Keep whole-program + a cost-model inliner** ("inline only if it shrinks", with
  let-sharing — purs-backend-es's `Semantics`). Addresses the compounding but not memory, and
  the contextual approximation already regressed benchmarks; the principled cost model is a
  large piece on its own. The architecture is the higher-leverage fix and is orthogonal (a
  better inliner can still be added later, per module).
- **Per-module separate wasm + link.** The intuitive "batch compiler" shape, but for wasm-GC
  it means sharing the runtime GC struct types across separately-built modules and turning
  every cross-module call into an import/export boundary — exactly the difficulty ADR 0009
  avoided by emitting one module. Rejected; single-wasm is retained.
- **Multi-wasm output** (ADR 0009's deferred escape hatch). For programs so large that even
  one Binaryen module + summaries does not fit; not this milestone.
- **Bigger Node heap.** The growth is geometric; no constant bound helps.
