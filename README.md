# PureScript Backend Wasm

An experimental WebAssembly backend for PureScript compiler

[![purs - v0.15.16](https://img.shields.io/badge/purs-v0.15.16-blue?logo=purescript)](https://github.com/purescript/purescript/releases/tag/v0.15.15) [![CI](https://github.com/purs-wasm/purescript-backend-wasm/actions/workflows/ci.yaml/badge.svg)](https://github.com/purs-wasm/purescript-backend-wasm/actions/workflows/ci.yaml)

## Overview

The compiler consumes `purs`'s CoreFn (`corefn.json`) and externs (`externs.cbor`)
output and produces a single WebAssembly module via the
[Binaryen](https://github.com/WebAssembly/binaryen) JS API.
It targets **Wasm　GC**, so heap values (ADTs, records, closures) are reclaimed by the host VM.

For more information, please consult [the documentation site](https://purs-wasm.github.io/documentation/getting-started/overview).

## Future Enhancements

- [x] Incremental build
- [ ] WASI support
- [ ] Monomorphization optimization

## Benchmarks

The **same PureScript source** compiled three ways and timed on one machine (lower
is better):

- **wasm** — this backend
- **JS (purs backend)** — `purs`'s stock JavaScript output
- **JS (with [purs-backend-es](https://github.com/aristanetworks/purescript-backend-optimizer))** — the optimizing JS backend

The wasm build is fastest on the **algorithmic** benchmarks, and completes the
deep-recursion `bintreeBfs` where both JS backends overflow the call stack (JavaScript
has no tail-call elimination). The margin is **widest on the allocation- and
recursion-heavy benchmarks** (`sumLoop` ~12×, `nqueens` / `bintreeDfs` ~2.5×) and
narrowest on the arithmetic ones (`fib` ~1.9×): much of the win comes from the compact
Wasm-GC value representation — tagged structs reclaimed by the host GC, versus JavaScript
object allocation — as well as from the arithmetic unboxing.

The **library higher-order benchmarks** turn on whether the `map`/`foldl` closure is
*specialized* (fused into a direct loop) or applied per element via an indirect `call_ref`
on boxed operands. `mapFold` left-folds a `Data.List`: its `map`/`foldl` use the
`where`-worker idiom, which a **post-inline specialization pass**
([ADR 0027](./docs/design-decisions/0027-specialize-after-inlining.md)) reaches once
inlining collapses the forwarder — so the closures fuse, cutting `mapFold` ~7× (from ~8×
behind `purs-backend-es` to roughly **on par** with it). It does not yet *beat* `purs-backend-es`:
the residual gap is that a `Data.List` `Int` element stays **boxed**, whereas V8 keeps it
unboxed — a separate cost that needs monomorphization (issue #19). `mapFoldArray` does the
same over a `Data.Array`, but its `map`/`foldl` are *foreign* (`ulib` `.wat`, no body to
specialize into), so the closure cannot be fused at all and it still trails further — **the
current frontier**; moving the array HOFs into PureScript over first-order primitives
(WasmBase, issue #26) is what lets ADR 0027 reach them too. Tracked in issue #5.

The **curry-vs-uncurry** graph isolates a property the wasm backend gets *for free*:
`Fn` / `EffectFn` lower to the same closures as curried code, so curried and uncurried
application are the same code (curried/uncurried time ~1.0 at every size). The same
PureScript on `purs-backend-es` pays ~3× for curried application across a dynamic boundary
(the stock `purs` backend's curried closures, by contrast, V8's escape analysis frees) —
so on wasm the JS habit of hand-uncurrying hot paths is genuinely unnecessary.

These benchmarks measure **steady-state throughput after warmup**: both the JS and
the Wasm code are run long enough for V8 to tier up hot code before timing, so the
results reflect optimized runtime performance rather than startup latency. The graphs
below are rendered and published to [GitHub Pages](https://purs-wasm.github.io/purescript-backend-wasm/)
by CI on each push to `main` (CI-runner timing is indicative — the curves, ratios, and
stack-overflow behaviour are the signal). Reproduce locally with `cd bench && npm run graph`.

| | |
|:---:|:---:|
| ![fib](https://purs-wasm.github.io/purescript-backend-wasm/fib.png) | ![sumLoop](https://purs-wasm.github.io/purescript-backend-wasm/sumLoop.png) |
| ![qsort](https://purs-wasm.github.io/purescript-backend-wasm/qsort.png) | ![nqueens](https://purs-wasm.github.io/purescript-backend-wasm/nqueens.png) |
| ![bintreeDfs](https://purs-wasm.github.io/purescript-backend-wasm/bintreeDfs.png) | ![bintreeBfs](https://purs-wasm.github.io/purescript-backend-wasm/bintreeBfs.png) |
| ![mapFold](https://purs-wasm.github.io/purescript-backend-wasm/mapFold.png) | ![countState](https://purs-wasm.github.io/purescript-backend-wasm/count-state.png) |
| ![countEffect](https://purs-wasm.github.io/purescript-backend-wasm/count-effect.png) | ![curry](https://purs-wasm.github.io/purescript-backend-wasm/curry.png) |

## Example

A small expression-language evaluator — an ADT, pattern matching, recursion, and
`Int` arithmetic (`example/src/Main.purs`):

```purescript
module Example.Main where

import Prelude

data Expr
  = Add Expr Expr
  | Mul Expr Expr
  | Neg Expr
  | Lit Int

eval :: Expr -> Int
eval = case _ of
  Add x y -> eval x + eval y
  Mul x y -> eval x * eval y
  Neg x   -> negate (eval x)
  Lit n   -> n
```

`eval` compiles to the wat below. The `Prelude` bundle (the `+` / `*` / `negate`
that lower to the `i32.add` / `i32.mul` / `i32.sub` intrinsics, plus the `$negate`
helper) and the host `i32` export shim are elided to keep the focus on `eval`;
identifiers are given readable names and the output is lightly reformatted.

Note what is **not** there: **`eval` allocates nothing**. Each constructor is a
struct *subtype* of the tag-only base `$Data`, so a match reads the tag by casting
to `$Data`, then a branch casts to the constructor's own struct and reads its fields
with `struct.get`. Arithmetic runs as unboxed `i32`, `eval` **returns** an unboxed
`i32`, and `Lit`'s `Int` field is stored unboxed — `Lit n` just reads an `i32` and
returns it. No dictionary closures, no `call_ref`, no `$Int` boxing. (The middle-end
eliminates the type-class dictionaries and unboxes the arithmetic; the concrete
`Int` field is unboxed from the externs type — see the
[`Int`/`Number` unboxing](docs/design-decisions/0013-int-number-unboxing.md) ADR.)

```wat
(module
 ;; Types (names added for readability; the optimiser emits numeric ids). Every
 ;; constructor is a struct subtype of the tag-only base $Data:
 ;;   $Data = (struct i32)                          -- the ctor tag; the cast target for a match
 ;;   $Bin  = (sub $Data (struct i32 eqref eqref))  -- Add / Mul: tag + two Expr fields
 ;;   $Un   = (sub $Data (struct i32 eqref))        -- Neg: tag + one Expr field
 ;;   $Lit  = (sub $Data (struct i32 i32))          -- Lit: tag + an unboxed Int field
 (export "eval" (func $eval$export))

 ;; --- elided: the Prelude bundle (intAdd / intMul / intSub intrinsics, the
 ;;     $negate helper) and the host i32 export shim ---

 (func $eval (param $0 eqref) (result i32)          ;; Expr -> Int — returns an unboxed i32
  (local $x eqref) (local $y eqref)
  (if (result i32)
   (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 0))  ;; tag 0 = Add?
   (then  ;; Add x y  ->  eval x + eval y
    (local.set $x (struct.get $Bin 1 (ref.cast (ref $Bin) (local.get $0))))
    (local.set $y (struct.get $Bin 2 (ref.cast (ref $Bin) (local.get $0))))
    (i32.add (call $eval (local.get $x)) (call $eval (local.get $y))))               ;; unboxed — no struct.new
   (else (if (result i32)
    (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 1)) ;; tag 1 = Mul?
    (then  ;; Mul x y  ->  eval x * eval y
     (local.set $x (struct.get $Bin 1 (ref.cast (ref $Bin) (local.get $0))))
     (local.set $y (struct.get $Bin 2 (ref.cast (ref $Bin) (local.get $0))))
     (i32.mul (call $eval (local.get $x)) (call $eval (local.get $y))))
    (else (if (result i32)
     (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 2)) ;; tag 2 = Neg?
     (then  ;; Neg x  ->  negate (eval x)
      (return_call $negate (call $eval (struct.get $Un 1 (ref.cast (ref $Un) (local.get $0))))))
     (else (if (result i32)
      (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 3)) ;; tag 3 = Lit?
      (then  ;; Lit n  ->  n   (the field is already an unboxed i32)
       (struct.get $Lit 1 (ref.cast (ref $Lit) (local.get $0))))
      (else (unreachable))))))))))
```
