# PureScript Backend Wasm

An experimental WebAssembly backend for PureScript compiler

[![purs - v0.15.16](https://img.shields.io/badge/purs-v0.15.16-blue?logo=purescript)](https://github.com/purescript/purescript/releases/tag/v0.15.15) [![CI](https://github.com/katsujukou/purescript-backend-wasm/actions/workflows/ci.yaml/badge.svg)](https://github.com/katsujukou/purescript-backend-wasm/actions/workflows/ci.yaml)

## Overview

The compiler consumes `purs`'s CoreFn (`corefn.json`) and externs (`externs.cbor`)
output and produces a single WebAssembly module via the
[Binaryen](https://github.com/WebAssembly/binaryen) JS API. It targets **Wasm
GC**, so heap values (ADTs, records, closures) are reclaimed by the host VM.

Currenlty supported features are listed in 
[`docs/supported-features.md`](docs/supported-features.md).

Key architectural decisions are recorded as ADRs under
[`docs/design-decisions/`](docs/design-decisions/).

## WIP

### PureScript language features

- [x] [Higher-order functions](./docs/supported-features.md#closures-and-higher-order-functions) with [full-support for partial/over application](./docs/supported-features.md#function-application-partial-and-over)
- [x] [strings](./docs/supported-features.md#strings), [arrays](./docs/supported-features.md#arrays) and [records](./docs/supported-features.md#records)
- [x] [ADT and pattern matching](./docs/supported-features.md#algebraic-data-types-and-pattern-matching)
- [x] [Recursive let-bindings](./docs/supported-features.md#recursive-let-bindings)
- [x] [Typeclass resolution](./docs/supported-features.md#typeclass-dictionaries), including cyclic instance groups (`Effect`'s Functor/Applicative/Monad)
- [x] [The `Effect` monad](./docs/supported-features.md#the-effect-monad) — collapses like a transparent monad (constant-stack loops), with effect order/count preserved
- [x] [User-defined FFI](./docs/supported-features.md#foreign-function-interface), including [effectful foreigns](./docs/interop.md#an-effectful-foreign) (`a -> Effect b`, the `console.log` shape)

### Optimizations

- [x] Scalar unboxing — `Int`/`Char` as `i32`, `Number` as `f64`, enum-like ADTs as `i31` tags (no heap box)
- [x] ADT field unboxing
- [x] Typeclass dictionary elimination
- [x] Inlining of Known-function (small or single-use, cycle-free) with β-reduction
- [x] record-accessor projection & case-of-known-constructor reduction
- [x] Lambda lifting
- [x] Higher-order specialization (static-argument transformation)
- [x] Tail-call elimination
- [x] Dead-code elimination
- [x] Effect reflection (impurification) + whole-program purity analysis
- [ ] Monomorphization

Please refer to the [docs/optimizations.md](./docs/optimizations.md) for detailed explanation.

### Other features

- [ ] Multiple platform support (browser/node/native)


## TODO

- [ ] Provide one-stop CLI for tryout (via Nix)

## Benchmarks

The **same PureScript source** compiled three ways and timed on one machine (lower
is better):

- **wasm** — this backend
- **JS (purs backend)** — `purs`'s stock JavaScript output
- **JS (with [purs-backend-es](https://github.com/aristanetworks/purescript-backend-optimizer))** — the optimizing JS backend

The wasm build is fastest on every benchmark, and completes the deep-recursion
`bintreeBfs` where both JS backends overflow the call stack (JavaScript has no
tail-call elimination). The margin is **widest on the allocation- and
pattern-match-heavy benchmarks** (`bintreeDfs` / `bintreeBfs`, ~5–8×) rather than the
arithmetic ones (`fib` ~1.6×): much of the win comes from the compact Wasm-GC value
representation — tagged structs reclaimed by the host GC, versus JavaScript object
allocation — as well as from the arithmetic unboxing. Higher-order code (`mapFold`,
which maps and left-folds a **polymorphic** list with closures) also wins: the
closures are specialized away into direct, non-allocating loops — even though a
polymorphic list element stays boxed (so this is a fair fight, with no
monomorphization advantage over JS's native numbers).

These benchmarks measure **steady-state throughput after warmup**: both the JS and
the Wasm code are run long enough for V8 to tier up hot code before timing, so the
results reflect optimized runtime performance rather than startup latency. Reproduce
with `cd bench && npm run graph`.

| | |
|:---:|:---:|
| ![fib](bench/results/fib.png) | ![sumLoop](bench/results/sumLoop.png) |
| ![qsort](bench/results/qsort.png) | ![nqueens](bench/results/nqueens.png) |
| ![bintreeDfs](bench/results/bintreeDfs.png) | ![bintreeBfs](bench/results/bintreeBfs.png) |
| ![mapFold](bench/results/mapFold.png) | ![countState](bench/results/count-state.png)|

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
