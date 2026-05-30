# 0004. Uniform `eqref` calling convention (boxed values)

- Status: Accepted
- Date: 2026-05-31

## Context

Slice 0 (scalar `Int` world) gave every value the unboxed wasm type `i32` and
exported functions with `i32` signatures directly. That only worked because
*every* value was an `Int`.

Once ADTs (and later records, closures) enter, values of different
representations flow through the same positions — e.g. `orElse :: OptInt ->
Int -> Int` has one boxed-ADT parameter and one `Int` parameter. CoreFn is
type-erased, so the code generator **cannot tell** from a function's IR which
parameters are `Int`, which are ADTs, etc. There is no per-position type to
key an unboxed representation on.

## Decision

Adopt a **uniform `eqref` calling convention**: every function parameter and
result, and every value that crosses a call or is stored in a heap value, is
the universal boxed type `eqref` (ADR 0001).

- `Int`/`Number`/`Char` are boxed (`(struct i32)` etc.); ADTs/records/closures
  are already reference types. All are subtypes of `eqref`.
- **Boxing is inserted only at the edges that need a raw scalar:** integer
  literals (box on creation), intrinsic machine ops (unbox operands, box the
  result), and the host boundary.
- **The `i32` host interface is preserved by export wrappers.** An exported
  `f :: Int -> Int` becomes a wrapper `(param i32) -> (result i32)` that boxes
  its argument, calls the internal all-`eqref` function, and unboxes the
  result. Slice 0's externally-observable `i32` exports are unchanged; only
  their internal representation becomes boxed.

This generalizes Slice 0's code path: there is one calling convention, derived
without any type information.

## Consequences

- Correct without types, and forward-compatible with closures (Slice 2's
  eval/apply already passes everything as `eqref`).
- Scalars are heap-allocated in ordinary positions, and Slice 0's previously
  unboxed arithmetic now boxes/unboxes around each op — a real cost.
- **Unboxing is deferred to an optimization pass** (consistent with ADR 0001):
  a later representation analysis can keep values unboxed where a function is
  used monomorphically, and raise export wrappers away. The
  immediate/unboxed-enum representation (OCaml-style constant constructors) is
  part of that same optimization scope.
- Pattern-match field projections yield `eqref`; using a field as an `Int`
  unboxes at the use site (typically inside an intrinsic).

## Alternatives considered

- **Representation inference now** (keep monomorphic `Int` unboxed in Slice 1).
  Faster code, but needs a type/representation analysis over the IR up front —
  a large prerequisite that contradicts ADR 0001's "unboxing is later". Deferred
  to the optimization phase.
- **Per-function ad hoc reps.** Without types there is no sound way to assign
  them; rejected.
