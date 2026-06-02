# 0013. Unboxing `Int` and `Number`

- Status: Approved
- Date: 2026-06-02

## Context

Under the uniform `eqref` value convention (ADR 0004) every value is an `eqref`,
and `Int`/`Char` are boxed as `$Int = (struct i32)`, `Number` as `$Num = (struct
f64)`. A heap struct is used (rather than the allocation-free `i31ref`) because a
PureScript `Int` is a full 32-bit value and `i31ref` holds only 31 bits — packing
an `Int` into an `i31` would silently overflow at 2³⁰. `Boolean` is the one scalar
that already avoids allocation: it boxes as an `i31ref` (0/1 fits).

The consequence is that **every arithmetic result allocates a heap object**: `acc +
i*i` builds three `$Int` structs per iteration, all immediately garbage. The
benchmark suite (`bench/`) makes this concrete — once dictionary elimination (ADR
0005) removed the dispatch overhead, the remaining cost is dominated by this
allocation/GC traffic. `sumLoop` went from a clean linear curve to a noisy one
*because* removing the linear dispatch term exposed the lumpy GC term underneath;
`bintreeBfs`/`qsort` (allocation-bound) barely improved.

This is the classic tension in compiling polymorphic functional languages:
parametric polymorphism (`forall a. a -> a`, `List a`) forces a **uniform
one-word representation**, which forces boxing. The standard resolutions are
tagged immediates (OCaml's `int`, Lisp fixnums, `i31ref` — cheap but narrower),
boxed-with-local-unboxing (GHC: `Int` = `I# Int#`, unboxed by strictness analysis /
worker-wrapper, fields unboxed by `{-# UNPACK #-}`), or whole-program
monomorphization (MLton, Rust). Our `Int` is exactly GHC's boxed `Int`, and WASM's
31-bit `i31ref` is why we pay a boxing cost that OCaml's 63-bit immediate `int`
avoids (OCaml boxes `int32`/`float`, and unboxes *those*, just as we will).

## Decision

Adopt GHC's strategy: keep the boxed uniform representation, and **choose a second,
unboxed representation per value where it provably stays monomorphic**, boxing only
at `eqref` boundaries.

- An `Int`/`Char` value is either a raw **`i32`** (unboxed, full 32-bit, no
  allocation) or a `$Int` heap struct (`eqref`); a `Number` is a raw **`f64`** or a
  `$Num`. `i31ref` is **not** used for `Int` (31-bit). `Boolean` stays `i31ref`
  (already allocation-free) and is **not** a target of this work.
- The IR already carries the chosen representation: `Rep = I32 | F64 | Boxed |
  CloRef` on every `Let` binding, every parameter, and the function result. The
  representation analysis sets these; codegen honours them and boxes/unboxes only
  where representations meet (`RBox`/`RUnbox` are not needed — the boundary
  coercions fall out of the rep on each binding and operand).

There are **two fronts**, pursued in order:

- **(A) Arithmetic-flow unboxing — no type information.** A representation analysis
  over `AnfExpr` keeps arithmetic results, intermediate values, loop accumulators,
  and monomorphic-`Int` function parameters/returns as `i32`/`f64`, inferred purely
  from value flow (an intrinsic produces/consumes `i32`; an ADT/record field, a
  polymorphic argument, a closure capture, the export ABI are `eqref` boundaries).
  This kills the per-iteration arithmetic allocation in `sumLoop`/`fib`/`dfsSum`.

- **(B) Data-field unboxing — type-directed.** A struct field whose type is
  concretely `Int` (e.g. `Node Int Tree Tree`, `Cons Int IntList`) is declared
  `i32` in the wasm struct rather than `eqref`, reading the field's type from the
  externs. This unboxes the `Int`s stored *inside* data structures, attacking the
  allocation in `qsort`/`bintree*`. A **polymorphic** field (`a` in `List a`)
  cannot be unboxed without monomorphization and stays `eqref` — out of scope here.

### Codegen contract (front A, machinery)

`genAtom` produces each atom at its *natural* representation (an `Int` literal is a
raw `i32`, a local at its slot's chosen rep). `genAtomAs ctx rep atom` coerces to
what a context needs — a no-op when already that rep, a box/unbox otherwise.
Intrinsics produce their natural result (raw `i32` for `Int` arithmetic), and a
`Let` boxes/unboxes the result only if the bound slot's rep differs. When every
slot is `Boxed` (the state before the analysis runs) this is **behaviour-neutral** —
literals box on use, arithmetic boxes into its slot, locals unbox into operands,
exactly as before. When the analysis marks a slot `I32`, those coercions become
no-ops and the value stays unboxed.

The function calling convention stays `eqref` for fronts A's first cut; unboxing
function parameters/returns (so a tail loop runs entirely in `i32`) is a later step
that changes per-function param/result reps via a whole-program fixpoint.

## Consequences

- Boxing is confined to representation boundaries (data fields, polymorphic calls,
  closure captures, the i32 export ABI). Monomorphic arithmetic and loops run
  allocation-free.
- `Int`s held in **polymorphic** containers (`Array Int`, `List a` at `Int`) remain
  boxed; eliminating that needs monomorphization, which we deliberately do not take
  on.
- The analysis is conservative: when a value's representation cannot be proven, it
  stays `Boxed` (correct, just not optimal). Correctness never depends on it.
- 32-bit semantics are preserved everywhere: unboxed `Int` is a full `i32`, and the
  `$Int` box's field is `i32`. No 31-bit truncation is introduced.

## Slices

- **U1 — codegen machinery (done):** representation-aware `genAtom`/`genAtomAs`,
  per-slot local types, per-intrinsic result reps, `genBody` boundary coercions.
  Verified behaviour-neutral (e2e unchanged) with the all-`Boxed` lowering.
- **U2 — front A analysis, local (done):** `Lower.Unbox.assignReps` assigns each
  `Let` slot a rep from a single, non-iterative pass: a slot is `I32`/`F64` when its
  rhs produces it unboxed (`Lower.Reps.primRep`) and at most one use boxes it (so the
  choice never adds a box), otherwise `Boxed`; demands come from `primOperandReps` and
  the fixed `eqref` contexts. Gated by the `--no-opt` flag alongside dictionary
  elimination. Measured (vs the unoptimized baseline): adds ~1.3–1.66× on top of
  dictionary elimination — fib 1.28→2.12×, sumLoop 1.93→2.65×, qsort 0.88→**1.32×**
  (the regression cleared), nqueens 2.45→3.26×, bintreeDfs 9.5→12.6×; `bintreeBfs`
  unchanged (its cost is the queue's structural allocation, not arithmetic).
- **U3 — front A, function ABI (done):** the analysis became whole-program. Function
  parameter / result *types* are inferred by a fixpoint over the type lattice
  (`⊤ ⊐ {I32, F64} ⊐ Boxed`): a parameter's type is the join of every argument passed
  to it, a result's the join of every value returned, a call result takes the
  callee's result type. Functions then take/return unboxed scalars; codegen coerces
  arguments to the callee's parameter reps and reads results at the callee's result
  rep (a `Sig` map in `Ctx`). Constraints that keep the wasm valid: a lifted **code
  function** keeps the fixed `$Code` ABI `(ref $Clo, eqref) → eqref`; an **exported**
  function's `f64` boundary stays `Boxed` (the host ABI is `i32`); a tail
  `return_call` is only emitted when the callee's result rep matches the caller's.
  Measured (vs the unoptimized baseline): bintreeDfs 12.6→**17.4×**, fib 2.12→2.28×,
  nqueens 3.26→3.41×; sumLoop flat at 2.65× (now bounded by the `Ordering`
  allocation in `>`, not `Int` boxing — a separate optimization).
- **B — front B field specialization:** type-directed `i32`/`f64` struct fields for
  concrete-scalar constructor/record fields, using externs types.
