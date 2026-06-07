# 0023. Polymorphic record update via runtime copy-and-set

- Status: ~~Proposed~~ **Accepted** _(2026-06-07: promoted — implemented (`RRecSet` across Lower/Codegen).)_
- Date: 2026-06-06

## Context

`examples/metatheory`'s typechecker — the first big-app target, now past the lowering
blowup of ADR 0022 — fails to link with:

```text
UnsupportedExpr "polymorphic record update (open row) is not yet supported"
```

The offending source is the `Writer`-style state threading, e.g. `x { warnings = … }` where
`x` has a **polymorphic** record type (a row variable: `{ warnings :: Array W | r }`). CoreFn
distinguishes the two record-update shapes by whether the untouched labels are statically
known:

- A **monomorphic** update (a closed record) carries the full set of *other* labels, so
  lowering rebuilds the record explicitly — `lowerObjectUpdate`'s `Just untouched` path:
  project each untouched label out of the original and `RMkRecord` a fresh value.
- A **polymorphic** update over an open row gives `copyFields = Nothing`: the extra fields
  (the `| r` tail) are *unknown at compile time*, so they cannot be enumerated and projected.
  This path currently `throw`s.

Records are type-erased to a runtime `$Rec = (struct (ref $LabelIds) (ref $Vals))` — parallel
arrays of interned `i32` label ids and `eqref` values (ADR 0001 / 0007). There is no static
layout and no type information at runtime, so the only way to update an open-row record is a
**dynamic copy**: duplicate the whole record and overwrite the named fields, carrying the
unknown tail fields across untouched.

## Decision

Lower a polymorphic record update to a **chain of runtime copy-and-set** operations over the
original record — one per updated field.

The runtime helper already exists: `$rt.recSet(rec, id, val)` (ADR 0017-era, exposed as
`Record.Unsafe.unsafeSet`'s `UnsafeSet` intrinsic). It copies the record's label-id / value
arrays and replaces the value at `id` (or inserts it, keeping the ids sorted), preserving
**every other field** — including the unknown open-row tail. That is exactly copy-and-set.

So `r { a = ea, b = eb }` (open row) lowers to `recSet (recSet r idA ea) idB eb`, with the
field labels interned to `i32` ids **at compile time** (the labels are statically known even
when the rest of the row is not) — no runtime string interning needed. A record update never
*adds* fields, so each `recSet` always hits the replace path.

### IR (`Lower.IR`)

A new right-hand side mirroring `RProjLabel` (which already projects by a compile-time-interned
label id):

```purescript
-- | Functional copy-and-set of one record field by interned label id (ADR 0023):
-- | `$rt.recSet rec labelId value`, preserving all other fields. Chained to lower a
-- | polymorphic (open-row) record update.
| RRecSet Atom Int Atom
```

### Lowering (`Lower.purs`)

`lowerObjectUpdate`'s `Nothing` case: lower the record to an atom, then fold the updates
left-to-right, each `lowerArg`-ing its value and binding an `RRecSet`:

```purescript
Nothing ->
  lowerArg env record \recAtom -> chainSet recAtom updates
  where
  chainSet rec ups = case Array.uncons ups of
    Nothing -> k rec
    Just { head: Tuple label e, tail } -> do
      labelId <- internLabel env label
      lowerArg env e \valAtom -> bindRhs (RRecSet rec labelId valAtom) \rec' -> chainSet rec' tail
```

The monomorphic `Just untouched` path is unchanged.

### Codegen (`Codegen.purs`)

`genRhs (RRecSet rec labelId val)` → `B.call recSetHelperName [recE, i32 labelId, valE]` (the
same helper `UnsafeSet` already calls). `rhsRep` is `Boxed` (the existing default). One case
added to each exhaustive `Rhs` walk (`Unbox.rhsDemands` — demand `Boxed` on `rec` and `val`;
the `Common` test helper `rhsAtoms`); the producer-rep / producer-ty walks fall through their
`Boxed` / `Bx` defaults.

## Consequences

- Polymorphic record updates compile and run; metatheory clears this gap. The behaviour
  matches the monomorphic path (a fresh record; the original is unmutated — `recSet` copies).
- **Cost: O(n) per updated field**, where n is the record width — each `recSet` copies both
  arrays. A k-field update over an n-field record is O(k·n) and allocates k intermediate
  records. Acceptable: open-row updates are not a hot path, and the alternative (a single
  fused copy) is a later optimisation, not a correctness need.
- No new runtime code — reuses `$rt.recSet`. The new IR node is a thin compile-time-id wrapper
  over the same call `UnsafeSet` already emits.

## Alternatives considered

- **A single fused runtime helper** `recSetMany(rec, ids[], vals[])` that copies once and
  overwrites k fields in one pass (O(n + k) instead of O(k·n), one allocation). Better
  asymptotics, but needs a new runtime function and an array-of-ids/array-of-vals calling
  convention. Deferred as an optimisation; chaining `recSet` is correct and simple now.

- **Reuse the `UnsafeSet` intrinsic** (`RPrim UnsafeSet [keyString, val, rec]`) instead of a
  new IR node. Works, but re-interns the label *string* at runtime via `internStr` on every
  update, even though the label is a compile-time constant — wasteful and against the
  interned-`i32`-id design that `RMkRecord` / `RProjLabel` already follow.

- **Require monomorphisation upstream** so every update is closed-row. Not possible here — the
  open row is inherent to the polymorphic state-threading code; there is no type information at
  this stage to close it.
