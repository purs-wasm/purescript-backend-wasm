# 0005. A high-level optimization IR

- Status: Proposed
- Date: 2026-05-31

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

Introduce a **high-level optimization IR between CoreFn and the current
lowering**, where the PureScript-level optimizations live: inlining, type-class
dictionary specialization/elimination, dead-code elimination,
case-of-known-constructor, and beta/simplification. The existing
`AnfExpr`/`Lower`/`Codegen` stay as the low-level target; Binaryen remains the
low-level optimizer. Representation optimizations that Binaryen cannot infer
because it does not know our boxing semantics — unboxing of monomorphic `Int`,
immediate (`i31`) nullary constructors, arity raising — are done as passes over
the `Rep`-carrying `AnfExpr`, not a separate low-level IR.

Target pipeline:

```
CoreFn
  → [new] high-level optimization IR   (inlining, dictionary elimination, DCE, case-of-ctor, beta)
  → AnfExpr (current)                  (closure conversion, eqref representation, decision trees;
                                        optional Rep-level unboxing / immediate-enum passes)
  → Binaryen → wasm                    (low-level optimization via optimize())
```

This is an *additive* evolution of ADR 0003: the new layer is inserted before
the existing lowering, which is unchanged.

## Consequences

- The big PureScript wins (especially dictionary elimination, which makes
  Prelude arithmetic compile to direct intrinsics and avoids runtime
  dictionary/closure overhead) become expressible.
- Slice 3 (records + type-class dictionaries) is the natural trigger. To keep
  correctness first, Slice 3 can run dictionaries *at runtime* (dictionaries as
  records, methods as projections, recursive value groups topologically sorted)
  with **no** optimization IR; the high-level IR and dictionary elimination come
  afterwards, on top of a working baseline.
- Adds a compilation stage and an IR to maintain; justified only by the
  optimization payoff, not by module size.

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
