# 0018. Native `effect`-package control-flow and `EffectFn` primitives

- Status: Accepted
- Date: 2026-06-04

## Context

The `effect` package ships FFI primitives the JS provider ladder (ADR 0014) cannot run
correctly, because they pass wasm closures (`Effect` thunks / loop bodies) across the JS
boundary — the same closure-marshalling gap that motivated native `Effect.Ref` (ADR 0017).
A coverage test (`examples/effect-prim`, `compiler/test/effectPrim.mjs`) showed only
`unsafePerformEffect` working; `forE`/`foreachE`/`runEffectFn` threw `type incompatibility
when transforming from/to JS`, and `whileE`/`untilE` threw `illegal cast`.

The affected APIs:

```purescript
forE     :: Int -> Int -> (Int -> Effect Unit) -> Effect Unit
foreachE :: forall a. Array a -> (a -> Effect Unit) -> Effect Unit
whileE   :: forall a. Effect Boolean -> Effect a -> Effect Unit
untilE   :: Effect Boolean -> Effect Unit
mkEffectFnN :: (a -> … -> Effect r) -> EffectFnN … r     -- N = 1..10
runEffectFnN :: EffectFnN … r -> a -> … -> Effect r
unsafePerformEffect :: forall a. Effect a -> a            -- already works
```

None need a host: a loop calling a PureScript closure is expressible directly in wasm.

## Decision

**Implement these as wasm-native intrinsics, resolved by qualified name (extending ADR
0017's `effectIntrinsic` table), with no JS.**

- **Loops → runtime helpers** (`runtime/runtime.wat`), each a wasm loop that applies the
  body/condition closure with the runtime trampoline `$callClo1`:
  - `forE(lo, hi, f)` — `for i in [lo,hi): perform (f i)`, i.e. `applyClo(applyClo(f, boxInt
    i), unit)`.
  - `foreachE(arr, f)` — the same over a `$Vals` array (`arrayGet`).
  - `whileE(cond, body)` — `while (unboxBool (perform cond)) { perform body }`.
  - `untilE(act)` — `while (!(unboxBool (perform act))) {}`.
  Each returns `Unit` (`i32` 0). An `Effect a` argument is a thunk (`$Clo`); *performing* it
  is `applyClo(thunk, unit)`.
- **`EffectFn` is the curried closure itself.** A PureScript closure is already an arity-1
  curried `$Clo`, so:
  - `mkEffectFnN` = **identity** (erased, like `unsafeCoerce`): the `EffectFnN` *is* the
    `a -> … -> Effect r` closure.
  - `runEffectFnN g x₁ … x_N` = `g x₁ … x_N` — apply `g` to the N args via an `applyClo`
    chain, yielding the `Effect r` thunk. It does **not** perform; the result is the
    `Effect`, performed by the caller (when `Perform` applies the unit, the standard
    saturating-application path applies it to the returned thunk). One `MkEffectFn` and one
    `RunEffectFn` intrinsic cover all N (the arity varies: `runEffectFnN` is N+1).
- **Arity includes the perform-unit** for the `Effect Unit`-returning loops (ADR 0017): the
  loops are performed via the unit-application path, so `forE` is arity 4, `foreachE`/
  `whileE` 3, `untilE` 2; the unit operand is dropped in codegen. The loop foreigns join
  `effectfulForeignNames` so the purity analysis preserves their `Perform`. `runEffectFnN`
  is *not* effectful itself (it builds an `Effect`); it is kept because its externs result
  type is `Effect r` (`effectfulForeignNamesFromSigs`).

`unsafePerformEffect` already works through the existing path (it performs a thunk once) and
is left as-is.

## Consequences

- `forE`/`whileE`/`untilE`/`foreachE`/`EffectFn` run entirely in wasm — no host import for
  `Effect`/`Effect.Uncurried`, and no closure crosses the JS boundary. `effectPrim.mjs` goes
  green and is wired into `test:bin`.
- The `effectIntrinsic` table now spans `Effect.Ref` (0017) and the `Effect` /
  `Effect.Uncurried` primitives; `mkEffectFnN`/`runEffectFnN` are matched by stripping the
  numeric suffix, so all N = 1..10 (and beyond) resolve without 20 literal entries.
- These are control flow over *opaque* effect bodies, so they do not by themselves collapse
  to straight-line code; they remain genuine wasm loops. That is the correct, predictable
  baseline. (A pure-`Effect` body still collapses inside the closure via ADR 0015.)
- Does not address the two pre-existing Effect-collapse bugs (a voided effect is dropped; a
  conditional effect on a runtime boolean traps) — those are separate ADR 0015 work and are
  what the fuller `examples/effect-ref` `main` still needs.
- Surfaced a separate **Effect-CAF-export** gap: a top-level `foo :: Effect a` whose body is
  a single expression (e.g. `foo = runEffectFn2 g a b`) is a CAF holding the thunk, and the
  export path does not perform it (the loader assumes the export *is* the performed result),
  so it traps when marshalled. Writing the body as a do-block makes it a performing
  computation and works. General (any bare-expression `Effect` CAF export), pre-existing,
  not specific to `EffectFn`; the `effFnTest` case uses the do-block form. To fix later in
  the export ABI (ADR 0011): an `Effect`-typed export that is a `$Clo` CAF must be
  `applyClo`'d with the unit.

## Alternatives considered

- **Fix the JS host path** (marshal `Effect` thunks / loop bodies across the boundary).
  Needs the deferred closure-direction-2 + JS-origin-opaque machinery (ADR 0014 /
  `docs/interop.md`), is slower (a JS loop re-entering wasm per iteration), and is
  unnecessary since the loops need no host.
- **Represent `EffectFnN` as a distinct uncurried wasm function type.** More machinery for
  no gain — the uniform arity-1 `$Clo` already models it, making `mkEffectFnN` a no-op.
- **ulib `foreign.wat`** (ADR 0012). Same representation; the intrinsic route keeps these in
  the always-available core, as with `Effect.Ref`.
