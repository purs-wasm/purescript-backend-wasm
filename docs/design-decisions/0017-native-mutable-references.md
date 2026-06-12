# 0017. Native `Effect.Ref` mutable references

- Status: Accepted
- Date: 2026-06-04

## Context

`Effect.Ref` (and `Control.Monad.ST`) provide a mutable cell. The standard library
implements them with FFI whose values are **JS objects** (`_new` returns `{ value }`).
Routed through the JS provider ladder (ADR 0014), that hits the JS-origin-opaque
limitation documented in `docs/developers-guide/interop.md`: a `Ref` created on the JS side cannot be held
by wasm and passed back to `read`/`write` — `MOpaque` is carried as the internal GC
`eqref`, but a JS object is an `externref`, so returning it to a `(result eqref)` import
throws `TypeError: type incompatibility when transforming from/to JS` at run time. The
general fix (carry JS-origin opaques as `externref`) is blocked on a representation
question and is out of scope.

But a `Ref` needs no host at all — it is a pure mutable cell. So it should be provided
**wasm-natively** rather than through JS.

## Decision

**Represent a `Ref` as a one-field mutable wasm-GC struct and implement its operations as
runtime helpers, resolved by the intrinsic table (ADR 0002).**

- The runtime (`runtime/runtime.wat`) declares `$Ref = (struct (field (mut eqref)))` and
  five helpers: `refNew` (`struct.new`), `refRead` (`struct.get`), `refWrite`
  (`struct.set`, returns `Unit` as the `i32` 0), `refNewWithSelf` (allocate with a null
  placeholder, apply the callback to the self ref, then fill it — knot-tying), and
  `refModify` (apply `f` to the current value, store the record's `state`, return its
  `value`; reuses `$callClo1` and `$rt.proj`). Nothing crosses to JS.
- `Effect.Ref`'s foreigns map to intrinsics (`RefNew`/`RefRead`/`RefWrite`/
  `RefNewWithSelf`/`RefModify`) by their **qualified** name (`effectRefIntrinsic`), not the
  bare-ident table — `read`/`write`/`new` are too generic to claim globally.
- An `Effect`-typed foreign intrinsic is **performed via the unit-application path**: its
  arity counts the value parameters *plus* the trailing `Effect` perform-unit (so `read`
  and `_new` are arity 2, `write` and `modifyImpl` are 3). `isEffectForeignApp` is made to
  treat any intrinsic as non-host so this path is always taken — even though source
  reconstruction (ADR 0016) also lists these foreigns in `foreignSigs` with an `MEffect`
  result. This is what makes an *unperformed* `Effect` value (e.g. `modify' = modifyImpl`)
  eta-expand to a proper thunk rather than eagerly running.
- `refModify` needs the `state`/`value` field ids of the record `f` returns. They are
  resolved in codegen through the emitted `internStr`, which shares the program's
  compile-time label table — so they match the ids the record's fields actually use.

A non-escaping `Ref` could be **demoted to a mutable wasm local** (scalar replacement),
erasing the heap cell — the imperative analogue of the State-monad collapse (ADR 0015),
and exactly what `Control.Monad.ST` is by construction (its region type guarantees
non-escape, so the demotion is always valid without analysis). That optimization is
**deferred**: it needs escape analysis for `Ref` and a correct heap `Ref` underneath it
for the escaping cases (a `Ref` passed to/captured by/returned to other code, or
`newWithSelf`). The native heap `Ref` here is that correct baseline; `ST` and the
local-demotion ride on the same `$Ref` representation later.

## Consequences

- `Effect.Ref` programs build with no host import for `Effect.Ref` and run entirely in
  wasm (verified: `new`/`write`/`modify`/`read` threaded through `Effect` do-notation
  return the expected value; bin-integration test `compiler/test/refNative.mjs`).
- Intrinsics being performed via the unit-application path is now load-bearing for
  correctness (not just the test counters): the arity must include the perform-unit, or an
  unperformed `Effect` value is mis-lowered to a value where a thunk is expected (caught:
  it surfaced as an `illegal cast` when the caller tried to run the "thunk").
- `Control.Monad.ST` shares the `$Ref` representation and helpers; wiring its foreign
  names is a small follow-up once their shapes are confirmed.
- Surfaced (separately, pre-existing — *not* introduced here, reproducible without `Ref`):
  the Effect-collapse layer drops a **voided** effect (`void e` / `modify_ = void <<<
  modify`) and mis-handles a **conditional** effect on a runtime boolean (`when b act` with
  non-constant `b` traps; a constant `b` folds and works). These block the fuller
  `examples/effect-ref` `main` and are tracked as Effect-collapse (ADR 0015) work.

## Alternatives considered

- **Carry JS-origin opaque values as `externref`** (fix the general limitation so the
  stock JS `Effect.Ref` works). Blocked on the polymorphic-identity representation problem
  (a value that is opaque by polymorphism but really a wasm-GC value must stay `eqref` to
  be `ref.cast`; a JS-native opaque must be `externref`; the boundary cannot tell them
  apart). Heavier and not needed for `Ref`, which needs no host.
- **ulib `foreign.wat` for `Effect.Ref`** (ADR 0012). Equivalent representation, but the
  intrinsic route keeps `Ref` in the always-available core and lets codegen resolve the
  record label ids; a ulib would still need the same `$Ref` struct.
- **Replace `Ref` with a mutable local unconditionally.** Unsound — only valid when the
  `Ref` does not escape. Kept as the deferred escape-analysis optimization on top of the
  native heap `Ref`.
