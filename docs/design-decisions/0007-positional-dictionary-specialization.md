# 0007. Positional (tuple) type-class dictionary specialization

- Status: ~~Proposed~~ **Accepted** _(2026-06-13: the decision is two-fold and accepted as such — (a) **keep** the interned-i32 label-map as the dictionary/record representation, which is shipped and load-bearing (`$Rec`/`$LabelIds`, dict elimination in the ADR-0005 IR); (b) **defer** positional (tuple) specialization as a future optimization, still unimplemented. The kept baseline is in production; the positional layout is deferred-within-Accepted.)_
- Date: 2026-05-31

## Context

ADR 0001 represents records — and, since type-class dictionaries are ordinary
records in CoreFn, dictionaries too — as a **uniform label-map**: a struct of
parallel `labels` and `values` arrays, with field access by runtime label
search. To defer the string runtime (Slice 4), labels are **interned to `i32`
ids** for now (`labels : (array i32)`), so projection is an `i32`-id search; the
`$Str`-keyed form and dynamic-string FFI (`Record.unsafeGet`) come with Slice 4.

A faster alternative was considered for dictionaries specifically: since a
dictionary's fields are *fully known at compile time* and never grow or shrink at
runtime, lay each dictionary out as a **positional tuple** and resolve every
method/superclass projection to a static index — O(1), no id array, no search.

We verified this against real `purs 0.15.16` CoreFn, including superclasses
(`Base ⇐ Derived`, `(Base, Derived) ⇐ Top`). Findings:

- A class becomes a **newtype dictionary constructor** `C$Dict`
  (`IsTypeClassConstructor` + `IsNewtype`, lowered as `\x -> x`) wrapping a record
  of the methods.
- A method accessor is `\dict -> case dict of C$Dict v -> v.method` — a newtype
  unwrap, so at *that* site the dictionary's class is syntactically known.
- A **superclass** dictionary is just another record field, with a generated
  label `<SuperclassName><index>` (`Base0`, `Derived1`), stored **thunked**
  (`\$__unused -> instanceDict`) to break initialization cycles.
- **Superclass access in consumer code is the problem.** It appears as
  `Accessor "Base0" (Var dictParam)` *directly on a bare dictionary parameter* —
  e.g. `useBaseViaDerived = \dictDerived -> baseOp (dictDerived.Base0 Prim.undefined)`,
  and nested for deeper chains (`(dictTop.Derived1 Prim.undefined).Base0 Prim.undefined`).
  The `Accessor` node carries **no class/type metadata** (`meta: null`) and CoreFn
  is type-erased, so there is *no syntactic marker* of which class `dictParam` is.

Consequently, static positional indexing requires **type information** — the
function's constraint types (from externs) plus propagation of dictionary class
through nested superclass projections. That complexity grows with hierarchy depth
and breadth (exactly the `Applicative`/`Bind`/`Monad`-style classes used heavily
in type-level metaprogramming). The label-map (interned-id search) needs **none**
of it: `Accessor "lbl" e` is an id search regardless of class, uniformly for
methods and superclass fields.

So the baseline (Slice 3) is the label-map; positional specialization is recorded
here as a *future optimization*, with its payoff estimated below.

## Decision (proposed)

Keep the **interned-`i32` label-map with runtime search** as the dictionary (and
record) representation. Treat **positional (tuple) dictionary specialization as a
later optimization performed in the type-aware high-level optimization IR
(ADR 0005), sequenced with/after type-class dictionary elimination** — not as a
standalone pass and not before elimination.

Rationale from the payoff estimate:

- **Per-projection cost.** Label-map projection is `ref.cast` + two `struct.get`s
  + a search loop over the id array (avg `n/2` iterations × ~5 instructions) +
  a final `array.get` — roughly **3–5×** the instruction count of positional
  access (`ref.cast` + `struct.get` + indexed `array.get`, ~3 instructions). But
  dictionaries are small (`n ≈ 1–5`), so this is a **small constant, not
  asymptotic**; loop/branch overhead dominates the comparison count.
- **Frequency.** In dictionary-passing style every method call projects at least
  once, and superclass access adds one projection + thunk application per level —
  pervasive in Prelude/monadic code (a hot path).
- **But it is not the bottleneck.** The dominant cost of naive dictionary-passing
  is dictionary **allocation** and **curried-closure indirection** (a `call_ref`
  per method application), which positional layout does *not* remove. The id
  search is a minor sub-cost.
- **And it is largely subsumed by dictionary elimination.** The first-order
  optimization (ADR 0005) inlines the instance and collapses
  `add dict x y → intAdd x y → i32.add`, removing the dictionary, projection,
  closure, *and* allocation for monomorphic code (the common case). What remains
  for positional layout to help is only genuinely polymorphic, non-eliminable
  dictionary passing.
- **Residual wins.** On that residual, positional layout gives a constant-factor
  speedup plus a real **memory saving** (drop the parallel id array → roughly
  half the dictionary size/allocation).
- **Shared prerequisite.** Positional specialization needs the *same* type
  information (constraint types from externs, dictionary-class propagation) that
  dictionary elimination needs — so it is cheap to add *within* that IR once the
  type infrastructure exists, and awkward to build standalone.

Net: the payoff is second-order and mostly subsumed by elimination; worth doing as
a follow-on inside the optimization IR (for residual polymorphism + the memory
win), at low priority.

## Consequences

- Slice 3 ships correct, superclass-robust dictionaries (label-map) with no type
  reconstruction, unblocking dictionary-passing E2E now.
- The optimization backlog gains a concrete, scoped item: positional dictionary
  layout as a follow-on to dictionary elimination in the ADR 0005 IR, justified by
  residual-polymorphism speedup and dictionary-size reduction, not by the common
  monomorphic path (which elimination already handles).
- No representation churn is forced on the baseline: the optimization, when built,
  chooses positional layout for dictionaries it can type, and leaves the label-map
  for the rest.

## Alternatives considered

- **Positional tuples as the Slice 3 baseline.** Rejected: superclass access on
  bare dictionary parameters carries no class marker, so it needs externs-driven
  type propagation whose complexity scales with class-hierarchy depth — the
  opposite of a correctness-first baseline.
- **Tuples but defer superclass-bearing classes.** Rejected: `Applicative`/`Bind`/
  `Monad` and type-level metaprogramming depend on rich superclass hierarchies, so
  deferring them guts the feature's value.
- **Hashing labels to `i32` instead of interning.** Rejected: interning is exact
  (no collisions) and equally string-free; hashing would need a collision story
  with no runtime label to disambiguate.

## References

- ADR 0001 — uniform label-map record/dictionary representation.
- ADR 0005 — high-level optimization IR (type-class dictionary elimination); the
  natural home for positional specialization.
- `purescript-backend-optimizer` — dictionary elimination on a CoreFn-derived IR,
  the source of `purs-backend-es`'s performance.
