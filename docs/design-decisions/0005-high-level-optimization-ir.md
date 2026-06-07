# 0005. A high-level optimization IR

- Status: ~~Proposed (module layout + migration plan firmed up; the IR's *shape* is
  still open — see Open questions)~~ **Accepted** _(2026-06-07: promoted — implemented. Open questions resolved — curried vs uncurried → **uncurried**; tree vs ANF/NbE → **NbE**. Actual submodules: `DictElim`/`Inline`/`Specialize`/`LambdaLift`/`Purity`/`Impurify`/`Semantics`/`Simplify`/`Analysis`.)_
- Date: 2026-05-31
- Revised: 2026-06-02

## Context

The pipeline today is `CoreFn → AnfExpr → Binaryen → wasm` with a single IR
(`AnfExpr`, ADR 0003). In practice `AnfExpr` sits at a *low* level: it is
already closure-converted (`RMkClosure`/`EnvField`/`RApply`), its representation
is committed to `eqref` boxing (ADR 0004), and pattern matches are decision
trees. It is the natural target of lowering, not a good place for high-level
optimization.

Comparable functional/wasm compilers use several IRs, each enabling a class of
optimizations. Grain (ML-family, wasm target) goes
`Anftree → Mashtree → … → Binaryen → wasm`, doing inlining and the like at the
high-level ANF and closure-conversion/representation work at the lower
`Mashtree`. Mapping that onto us:

| Grain                     | Here                                   |
| ------------------------- | -------------------------------------- |
| Anftree (high-level opts) | *missing*                              |
| Mashtree (closure-conv'd) | `AnfExpr` (current IR)                 |
| Binaryen → wasm           | Binaryen → wasm                        |

So the layer we lack is the **high-level optimization IR** — one that still has
lambdas and dictionaries as ordinary values, *before* closure conversion and
boxing, where PureScript-specific optimizations are expressible.

The single most valuable such optimization is **type-class dictionary
elimination**: `x + y` is `Data.Semiring.add semiringInt x y` → a dictionary
projection → `intAdd`; inlining the instance collapses it to a direct `intAdd`.
This is exactly what `purescript-backend-optimizer` (the `purs-backend-es`
backend) does on its own CoreFn-derived IR, and it is the source of that
backend's performance. It can only be done cleanly *before* closure conversion.

Conversely, most *low-level* optimization (constant folding, DCE, local
coalescing, function inlining at the wasm level) is already performed by
Binaryen's optimizer (`mod.optimize()`), so a thick low-level IR is low value.

## Decision (proposed)

Introduce a **high-level optimization IR (the "middle IR", MIR) between CoreFn and
the current lowering**, as a new `MiddleEnd` subsystem, where the PureScript-level
optimizations live: inlining, type-class dictionary specialization/elimination,
dead-code elimination, case-of-known-constructor, beta/simplification, and the
**lambda lifting / supercombinator conversion** currently done as a CoreFn pre-pass
(`Lower.LambdaLift`, added for tail-call elimination — its proper home is here). In
the MIR, lambdas and dictionaries are still ordinary values (before closure
conversion and boxing).

The existing `AnfExpr`/`Codegen` stay as the low-level target and Binaryen remains
the low-level optimizer. Representation optimizations Binaryen cannot infer because
it does not know our boxing semantics — unboxing of monomorphic `Int`, immediate
(`i31`) nullary constructors, arity raising — are passes over the `Rep`-carrying
`AnfExpr`, not a separate low-level IR.

Target pipeline (three explicit phases):

```
CoreFn
  → Transl    → MIR        faithful, mechanical translation (no optimization)
  → Optimize  → MIR        inlining · dictionary elimination · lambda lifting ·
                           uncurrying · DCE · case-of-ctor · beta (driven to a fixpoint)
  → Lower     → AnfExpr    closure conversion (RMkClosure/EnvField), eqref boxing,
                           decision trees; optional Rep-level unboxing / immediate-enum
  → Codegen → Binaryen → wasm    low-level optimization via optimize()
```

This restructures rather than purely extends the lowering: **`Lower` now consumes
the MIR, not CoreFn.** The two halves of "handling functions with free variables"
separate cleanly — *lambda lifting* (which functions become top-level
supercombinators / direct calls) is an `Optimize` pass; *closure conversion*
(making the captured environment explicit) stays in `Lower`. Decision-tree pattern
compilation (`Lower.Match`) likewise stays in `Lower`.

### Module layout

A `PureScript.Backend.Wasm.MiddleEnd` subsystem (sibling of `Lower` / `Codegen`):

```
MiddleEnd/
  IR / Types     the MIR representation (functions, applications, dictionaries,
                 lambdas, case, let as ordinary high-level values)
  Monad          the optimization monad: a fresh-name supply, accumulated
                 top-level declarations, an analysis environment (known functions
                 + arities, inlinable definitions, usage counts), a change flag
  Transl         CoreFn → MIR — faithful, no optimization
  Optimize       the pass driver: sequences / iterates the passes to a fixpoint
  Optimize/
    LambdaLifting   self-recursive (and known) local functions → top-level
                    supercombinators (migrated from `Lower.LambdaLift`)
    Inline, Uncurry, Dce, BetaReduce, CaseOfCtor, DictElim, …
```

`Optimize` is the orchestration (a pass pipeline), not a bare re-export aggregator;
each `Optimize/*` module is a single-responsibility pass.

## Migration plan

Introduce the layer **behaviour-neutrally first**, then add optimizations
incrementally, so the large refactor stays test-driven at each step:

1. **Skeleton (no optimization).** Define the MIR + `Transl` (CoreFn → MIR) + a
   `Lower` that consumes the MIR and reproduces today's output with **zero**
   optimization passes. Whole suite green. This is the risky structural step, done
   as a pure, behaviour-preserving refactor.
2. **Migrate lambda lifting.** Reimplement the `Lower.LambdaLift` transform as
   `Optimize/LambdaLifting` over the MIR; delete the CoreFn pre-pass. (The MIR —
   uncurried, known-function-aware — should make it cleaner than wrestling raw
   curried CoreFn.)
3. **Add passes one at a time.** Starting with the headline **dictionary
   elimination**, then inlining / uncurrying / DCE / case-of-ctor, each behind
   tests and an output comparison.
   - Reachability DCE (today `Lower.Collect`) splits into a coarse pre-`Transl`
     filter (don't translate unreachable functions) and a finer `Optimize/Dce`.

## Open questions

The **shape of the MIR is not yet decided** — it is the central design question, to
settle before step 1, because it governs how much the optimizations can do:

- **Curried vs uncurried (arity-explicit).** Uncurrying makes saturation checks,
  lambda lifting, and inlining far simpler (the current `Lower.LambdaLift` struggles
  precisely because saturated self-calls are buried in a curried `call_ref` chain).
- **Tree vs ANF / NbE.** A CoreFn-like tree is straightforward; a
  normalization-by-evaluation core (à la `purescript-backend-optimizer`) is stronger
  for inlining/specialization but more involved.
- **How much dictionary structure is resolved in `Transl`** (e.g. to label-maps)
  vs kept abstract for `Optimize/DictElim` to specialize.
- The optimization monad's exact effects, and whether `Optimize` runs a fixed
  schedule or a true fixpoint.

## Consequences

- The big PureScript wins (especially dictionary elimination, which makes
  Prelude arithmetic compile to direct intrinsics and avoids runtime
  dictionary/closure overhead) become expressible.
- The **runtime-dictionary baseline this layer builds on now exists**: records and
  type-class dictionaries run at runtime (dictionaries as records, methods as
  projections; recursive value groups per ADR 0008) and most of `Prelude` compiles
  and runs without any optimization IR. So the layer is now the targeted next step,
  on top of a working baseline, rather than a prerequisite for correctness.
- **`Lower.LambdaLift` is the first inhabitant to migrate in.** It was added (as a
  CoreFn pre-pass) for tail-call elimination — turning self-recursive local
  functions into top-level supercombinators so their tail self-calls become direct
  `return_call`s — but it is an optimization and belongs in `Optimize`.
- `Lower` is reworked to consume the MIR (no longer CoreFn); closure conversion and
  decision-tree compilation stay in it. This is a larger change than ADR 0003's
  purely-additive framing implied, mitigated by the behaviour-neutral migration.
- Adds a compilation stage and an IR to maintain, introduced to make
  PureScript-specific optimizations (above) expressible and justified by that
  payoff.

## Alternatives considered

- **Optimize on the existing `AnfExpr`.** Rejected for the high-level
  optimizations: after closure conversion and `eqref` boxing, dictionaries and
  lambdas are gone, so inlining/dictionary-elimination are far harder. (Some
  *representation* passes do belong here — see Decision.)
- **A thick low-level IR (Grain's Mashtree analogue).** Low value: Binaryen's
  optimizer already covers most low-level optimization.
- **Rely solely on Binaryen.** Binaryen cannot perform PureScript-level
  optimizations (it does not understand dictionaries, closures, or our boxing),
  so the high-value transforms would never happen.

## References

- Grain compiler walkthrough — multi-IR pipeline (`Anftree`/`Mashtree`):
  <https://github.com/grain-lang/grain/blob/main/docs/contributor/compiler_walkthrough.md>
- `purescript-backend-optimizer` (the `purs-backend-es` backend) — CoreFn → an
  optimization IR with inlining and dictionary elimination.
