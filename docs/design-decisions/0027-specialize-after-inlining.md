# 0027. Specialize after inlining: the `where`-worker / forwarder idiom

- Status: ~~Proposed~~ **Accepted** _(2026-06-10: promoted — implemented: post-inline `specializeProgram` + β-only simplify in `MiddleEnd` (what makes the PureScript shadows specialize).)_
- Date: 2026-06-08

## Context

Higher-order specialization (the static-argument transformation, ADR 0005,
`MiddleEnd/Optimize/Specialize.purs`) fires for a call `f(<lambda>, …)` only when `f` is a
*candidate*: a single self-recursive `Rec` (or a `NonRec`) whose function parameter is
**applied in its body** (`staticFnParams` / `isApplied`) and passed **unchanged** through
its own recursion (`allSelfCallsPass`). `MiddleEnd.runOpt` runs it **once**, whole-program,
**after** lambda-lifting but **before** the per-module inlining stage (`localOpt`):

```
lifted      = lambdaLift …
specialized = specializeProgram lifted   -- once, pre-inlining
ordered     = topoOrder specialized
result      = foldl localOpt … ordered   -- inlining happens here
```

The common PureScript HOF idiom defeats this:

```purescript
foldlA f z xs = go 0 z
  where
  go i acc = if i >= n then acc else go (i + 1) (f acc (unsafeIndex xs i))
```

Lambda-lifting splits it into a **forwarder** `foldlA` (passes `f` to the worker, never
applies it) and a **worker** `go$liftN` (applies `f`, recurses passing `f` unchanged). At
specialize time the literal lambda sits at the *forwarder's* call site — but `foldlA` is not
a candidate (it does not apply `f`), and the worker's only call sites pass the forwarded
*variable* `f`, never a literal lambda. So nothing specializes. The lambda reaches the
worker's call site only **after** inlining collapses the forwarder — too late for the single
pre-inline pass.

**Evidence.**

- PoC (`compiler/test/fixtures/PocArrFold`): `foldlA` (the `where`-worker above) is **not**
  specialized — `sumA = go$lift0(length xs, \acc x -> add(acc, x), xs, 0, 0)`, the lambda a
  runtime argument. The flat, forwarder-free shape `foldlB f i n xs acc = … foldlB f …` (a
  top-level self-recursion that applies `f` directly) **is** specialized — `foldlB$spec0`
  with the lambda fused in.
- Bench (`Bench.Main`): `Data.List` `map` / `foldl` lower to `chunkedRevMap$lift0` /
  `go$lift3` that receive their closures as **runtime arguments** — *not* specialized —
  exactly like the foreign `Data.Array` `arrayMap` / `foldlArray`. So **neither the
  idiomatic `Data.List` HOFs nor the foreign `Data.Array` HOFs specialize today.** This
  corrects the prior belief (README/notes) that pure-PureScript HOFs "specialize away into a
  direct loop": they do not, when written with the `where`-worker idiom (which `Data.List`
  uses).

**Validation.** Running `specializeProgram` a **second time on the fully-optimized program**
— after `localOpt` has collapsed the forwarders, so the lambda now sits at the worker's call
site — specializes them: `chunkedRevMap$lift0$spec0`, `go$lift3$spec18` appear with the
closures fused, across the whole program (`map`/`foldl`/`append`/`quicksort`/…). The
substitution leaves `(\… -> …)(…)` redexes that a follow-up β-reduction collapses.

## Decision

Add a **post-inline specialization pass** so the specializer sees the call sites that only
materialize after the forwarder is inlined. After the dependency-ordered `localOpt` stage:

1. run `specializeProgram` again on the optimized program, then
2. run a **β/reduce-only simplify** (empty inline set — as `localOpt`'s second simplify
   already does) to collapse the redexes the static-argument substitution leaves.

This reuses the existing, proven specializer unchanged — the flat shape already works; the
second pass merely exposes the `where`-worker shape to it. The current pre-inline pass stays
(it catches direct-lambda call sites early and keeps later inlining smaller).

**Scope.** This handles single self-recursive / `NonRec` workers (the existing `funcOf`
candidate set). **Mutually-recursive worker groups** (e.g. `listMap`'s
`chunkedRevMap`/`reverseUnrolledMap`/`unrolledMap`) remain excluded — `funcOf` admits only a
single `Rec`/`NonRec`. (The validation showed several lifted workers *do* reduce to single
self-recursion after lifting and so are covered; the mutual-group case is the residual,
deferred extension.)

### Why a bounded pass, not pipeline iteration

A natural alternative is to iterate the *whole* optimization pipeline to a fixed point (some
compilers do — e.g. Grain runs its optimization pipeline four times). For **this** backend
that is exactly the shape ADR 0021 removed: the old whole-program optimizer ran the pipeline
up to `maxRounds = 8` and **OOM'd** on `examples/metatheory` (~11.6 GB; node count ~doubled
each round). The cause is that our **inlining (NbE simplify) is not contracting** — it is
not idempotent on dictionary chains, so re-running it *re-expands* an already-optimized
program (`monadStateT(…).Applicative0(…)…map` grows every round). Fixpoint iteration is the
textbook approach, but it is only safe when each pass is contracting (reduces or converges);
ours is not, so iterating diverges. Grain can iterate because its passes are
contracting/idempotent.

So ADR 0027 adds a **bounded** step, not a loop: one more `specializeProgram` plus a
**β/reduce-only** simplify (`inline = Map.empty`). The β-only simplify *is* contracting (it
collapses redexes, never re-inlines) — the same mechanism `localOpt`'s second simplify
already relies on to collapse impurify's thunks without re-expanding the module — and
`specializeProgram` is itself bounded (it creates specializations, it does not loop-expand).
A single bounded pass cannot compound the way the N-round loop did.

The general "iterate safely" path is **ADR 0020 stage 3 (reduction-aware inlining)**: inline
only when it reduces, share otherwise, which makes inlining contracting. Once that lands,
fixpoint iteration of the whole pipeline becomes viable and this post-inline specialization
should fold into that general loop rather than remaining a bespoke extra pass. Until then,
the bounded pass is the safe move.

## Consequences

- **Idiomatic `Data.List` HOFs specialize** — `map`/`foldl`/`filter` over lists lose the
  per-element `call_ref`; List gets faster.
- **WasmBase (ADR 0026) Array HOFs specialize regardless of authoring style** — removing the
  need for a fragile "write HOFs flat" discipline in the repositioned `ulib`. Authors write
  natural PureScript.
- **User HOFs written naturally (with `where` workers) specialize** — a general win, not
  just for library code.
- **Reframes #5.** The dominant cause of HOF slowness is the `where`-worker / forwarder gap
  (which affects pure-PureScript `Data.List` too), with the foreign boundary a *second*,
  separate barrier that WasmBase (ADR 0026) addresses by moving the higher-order layer into
  PureScript. #5 needs *both*: this pass **and** WasmBase.
- **Does not address element boxing (cost (b), #19)** — specialization removes the closure
  indirection (cost (a)); boxed `Int` elements remain until monomorphization.
- **Risk — ADR 0021 compounding.** A second whole-program specialize + simplify must not
  reintroduce the N-round re-optimization that OOM'd the optimizer on transformer-heavy code.
  Mitigations: the follow-up simplify is β/reduce-only (no re-inlining), and the pass is
  single (not looped). **This must be validated against the `examples/metatheory` build (ADR
  0021's stress case) before acceptance** — if it compounds, fall back to interleaving
  specialization into `localOpt` per module (see Alternatives).

## Alternatives considered

- **Flat-authoring discipline in `ulib` only (zero compiler change).** Write the repositioned
  `ulib` HOFs in the forwarder-free, flat self-recursive shape (which already specializes).
  Rejected as the whole answer: it fixes WasmBase Array HOFs but **not** `Data.List`
  (upstream, `where`-worker) nor user code, and a "don't use `where` workers" rule is fragile
  and un-idiomatic. (It remains a viable *stopgap* for `ulib` until this pass lands.)
- **Specialize *through* forwarders without inlining** (transitive static-argument
  propagation: detect that `foldlA` forwards `f` to `go$liftN` and propagate the lambda).
  Rejected: more complex, and re-implements what inlining already does — the post-inline form
  is simpler to specialize.
- **Interleave specialization into `localOpt` per module** (specialize after each module's
  inline, with the spec placed in the *caller's* module). Fits ADR 0021's per-module model
  and avoids a whole-program second pass, but needs `createSpec` to target the caller's
  module and is more invasive. The leading fallback if the global second pass compounds.
- **Leave as-is, rely on WasmBase flat HOFs.** Rejected — leaves `Data.List` and user HOFs
  slow, which are the dominant cases.

## References

- Issue #5 (foreign/ulib higher-order specialization) — reframed: the `where`-worker gap is
  the dominant cause; the foreign boundary is the second barrier.
- ADR 0026 (WasmBase) — its PureScript HOFs need this pass to specialize.
- ADR 0021 (streaming, dependency-ordered optimization) — the `localOpt` structure this pass
  extends, and the compounding constraint it must respect.
- ADR 0005 (high-level optimization IR) — the specialization pass itself.
- ADR 0020 (reduction-aware inliner) — the simplify/NbE machinery the follow-up reduction uses.
- Regression guard:
  `Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize` — the
  "forwarder / where-worker idiom after inlining (optimizeProgram)" case. (The finding was
  first reproduced with a throwaway `PocArrFold` fixture + a `Bench.Main` whole-program dump
  via `dump-opt.mjs`.)
