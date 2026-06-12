# 0008. Constructing recursive type-class dictionary groups

- Status: Accepted
- Date: 2026-06-01

## Context

Earlier notes (ADR 0005 / 0006, and the roadmap) said Slice 3 could run
dictionaries at runtime with "recursive value groups **topologically sorted**".
That shorthand is imprecise: a type-class instance group can be **genuinely
cyclic**, and a plain topological sort cannot linearize a cycle. This record
makes the actual situation — and how construction is ordered — precise, so the
question does not have to be re-derived each time it comes up (especially once
`Effect` and monad hierarchies are in scope).

### The cycle is real

`Effect`'s instances are the canonical example. Only `pure`/`bind` are FFI; the
rest are defined *through* the monad:

- `functorEffect.map = liftA1` → `liftA1`'s `Applicative` constraint → `applicativeEffect`
- `applyEffect.apply = ap` → `ap`'s `Monad` constraint → `monadEffect`
- `applicativeEffect` →(superclass `Apply`)→ `applyEffect`
- `bindEffect` →(superclass `Apply`)→ `applyEffect`
- `monadEffect` →(superclasses `Applicative`, `Bind`)→ `applicativeEffect`, `bindEffect`
- `applyEffect` →(superclass `Functor`)→ `functorEffect`

The whole set is one strongly-connected component: e.g.
`applyEffect → monadEffect → applicativeEffect → applyEffect`. A plain
topological sort of this graph is impossible.

### Why it still resolves: superclass fields are thunked

The decisive CoreFn fact (verified, see `Slice3b` and
`[[corefn-typeclass-shapes]]`): **superclass dictionaries are stored as deferred
thunks** — `Base0: \$__unused -> baseInt` — while **method fields are eager**
(`apply = ap monadEffect`, `map = liftA1 applicativeEffect`).

Split the value-reference graph by which edges actually fire during
construction:

- **Eager edges** = method fields. They point *up* the hierarchy (a method uses
  a higher dictionary): `applyEffect → monadEffect`, `functorEffect → applicativeEffect`.
- **Lazy edges** = superclass fields. They point *down* (`Monad → Applicative →
  Apply → Functor`) and are all behind a thunk.

Every back-edge that closes a cycle is a *superclass* edge, hence thunked. So the
**eager construction-dependency graph is acyclic** (a DAG of upward edges).
Building `applyEffect` calls `monadEffect()` to capture it in `ap monadEffect`,
but `monadEffect`'s own fields are all superclass thunks, so it builds without
calling back — the recursion stops. The cycle lives entirely in deferred thunks
and does **not** constrain construction order.

## Decision

1. **Honor the CoreFn superclass thunks.** Compile a superclass field as the
   closure CoreFn gives (`\_ -> siblingDict`), not as an eager reference.

2. **Order construction by a topological sort of the *eager* (post-thunking)
   dependency graph**, not the full reference graph. That subgraph is a DAG, so
   the sort is always well-defined. This is the precise form of the
   "topologically sorted" shorthand in ADR 0005 / 0006.

3. **For sharing / efficiency, memoize** (the same penalty as ADR 0006's CAFs:
   without it each reference rebuilds the dictionary; see
   `docs/developers-guide/supported-features.md`). Two viable mechanisms:
   - **CAF globals (preferred, ADR 0006):** build each dictionary once into a
     module global; forcing a superclass thunk then reads the cached dictionary.
   - **Knot-tying (the Slice 2 closure technique):** allocate every group
     member's `$Rec` struct first, then back-patch the sibling-referencing slots
     of the (mutable) values array. Valid here because every cross-reference is a
     *reference* (superclass field) or a *PAP capturing a reference*
     (`ap monadEffect`) — none reads a sibling's contents at construction. This
     also lets us drop the thunks and store direct references.

4. **Reserve true `$runtime_lazy`-style laziness** (a memoized init-once thunk
   plus a "needed before initialized" guard, as the JS backend uses uniformly)
   for the cases the above does not cover: a pathological *eager* cycle that
   superclass-thunking does not break, or recursive **non-dictionary** value
   bindings. Adopt it only when such a case actually arises.

### Scope

Near-term Prelude arithmetic (`Semiring`/`Ring`/…) has linear superclass chains
and directly-defined instances, so its instance graph is acyclic even *including*
superclass edges — a trivial topological sort. The cyclic case (`Effect` and
monad hierarchies) is deferred with `Effect`; when reached it is handled by
honoring the superclass thunks plus either ADR 0006 memoization or knot-tying,
per the decision above.

## Consequences

- The construction-ordering story is now precise: topological sort applies to the
  **eager** subgraph; the cycle is carried by lazy superclass thunks. Future work
  on `Effect`/monads can start from this rather than rediscovering it.
- No new mechanism is forced now: with the superclass thunks honored, even the
  current (un-memoized) scheme *terminates* and is correct — it only rebuilds
  dictionaries per reference (the documented performance penalty), which ADR 0006
  removes.
- Knot-tying is established as a second, lazy-free option that reuses the Slice 2
  closure machinery and yields sharing without thunks.
- Genuine laziness (`$runtime_lazy`) is scoped down to a fallback for pathological
  or non-dictionary recursive values, rather than a blanket requirement.

## Alternatives considered

- **Plain topological sort of the full reference graph.** Impossible: the group
  is a true cycle. (This is the imprecision this record corrects.)
- **`$runtime_lazy` for all instance groups (the JS backend's uniform choice).**
  Correct and also memoizing, but heavier than needed for the common case, where
  superclass-thunking already makes construction acyclic and knot-tying/CAF
  globals give sharing. Kept as a fallback (Decision §4).
- **Eagerly inlining/eliminating dictionaries so the group never exists.** That is
  dictionary elimination (ADR 0005); it removes many dictionaries but not the
  need to *construct* those that genuinely survive as runtime values, so this
  record still applies to the residual.

## References

- ADR 0001 — record/dictionary representation (the `$Rec` label-map).
- ADR 0005 — dictionary elimination (removes many, not all, runtime dictionaries).
- ADR 0006 — CAFs as globals (the memoization that makes per-reference rebuilds
  build-once).
- ADR 0007 — positional dictionary specialization (orthogonal: layout, not
  construction order).
- `[[corefn-typeclass-shapes]]` — the verified CoreFn encoding (superclass thunks,
  method accessors, instance CAFs).
