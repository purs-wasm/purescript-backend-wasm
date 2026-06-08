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

## WASM vs JS

How this backend differs from a JavaScript backend (`purs` / `purs-backend-es`). Most of
PureScript behaves identically; the wasm-specific points worth knowing:

- **Strings are UTF-8 byte arrays.** A `String` is its UTF-8 bytes, so `length` counts
  *bytes* (not UTF-16 code units) and ordering is by code point — a deliberate divergence
  from `Data.String.CodeUnits`. See [Runtime representation](./docs/runtime-representation.md#string).
- **`Effect` (and monadic loops) run in constant stack.** `Effect` / `State` do-blocks
  collapse to flat loops, so deep effectful recursion that overflows a JS backend (whose
  bind chain is not tail-call-optimized) runs flat here. See
  [Optimizations](./docs/optimizations.md#worked-example-the-effect-monad).
- **Manual uncurrying rarely pays.** `Fn` / `EffectFn` lower to the *same* arity-1 closures
  as curried code (`mkFnN` is the identity, `runFnN` is the saturated apply), so curried and
  uncurried application are the *same* code on wasm. The [curry benchmark](#benchmarks)
  confirms it — curried/uncurried time is ~1.0 on wasm regardless of size, while
  `purs-backend-es` pays ~3× for curried application through a dynamic boundary. So the JS
  habit of hand-uncurrying hot paths (e.g. Halogen VDom) is unnecessary here. See
  [Optimizations](./docs/optimizations.md).
- **Values are wasm-GC heap objects**, managed by the host garbage collector — no linear
  memory, no manual allocation. `Boolean` is an unboxed `i31`; `Int` / `Number` unbox to
  `i32` / `f64` where boxing is unnecessary. See [Runtime representation](./docs/runtime-representation.md).
- **Records and type-class dictionaries share one representation** (a label-map), and most
  dictionaries are eliminated outright by the optimizer. See
  [Optimizations](./docs/optimizations.md#dictionary-elimination).
- **Polymorphic containers still box their elements** (as JS does) — unboxing applies to
  concrete scalar fields; removing it would need monomorphization (out of scope). See
  [Optimizations § Known gaps](./docs/optimizations.md#known-gaps).
- **Crossing to JS is an explicit marshalling boundary** (scalars cross raw; strings,
  arrays, records, closures are marshalled). See [JS↔WASM interop](./docs/interop.md).

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

Toward a **v0.1** release:

- [ ] Real `bin` implementation — production linker (streaming, dependency-ordered codegen; ADR 0009 / 0021)
- [ ] Publish to npm
- [ ] One-stop CLI for tryout (via Nix)

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
below are rendered and published to [GitHub Pages](https://katsujukou.github.io/purescript-backend-wasm/)
by CI on each push to `main` (CI-runner timing is indicative — the curves, ratios, and
stack-overflow behaviour are the signal). Reproduce locally with `cd bench && npm run graph`.

| | |
|:---:|:---:|
| ![fib](https://katsujukou.github.io/purescript-backend-wasm/fib.png) | ![sumLoop](https://katsujukou.github.io/purescript-backend-wasm/sumLoop.png) |
| ![qsort](https://katsujukou.github.io/purescript-backend-wasm/qsort.png) | ![nqueens](https://katsujukou.github.io/purescript-backend-wasm/nqueens.png) |
| ![bintreeDfs](https://katsujukou.github.io/purescript-backend-wasm/bintreeDfs.png) | ![bintreeBfs](https://katsujukou.github.io/purescript-backend-wasm/bintreeBfs.png) |
| ![mapFold](https://katsujukou.github.io/purescript-backend-wasm/mapFold.png) | ![countState](https://katsujukou.github.io/purescript-backend-wasm/count-state.png) |
| ![countEffect](https://katsujukou.github.io/purescript-backend-wasm/count-effect.png) | ![curry](https://katsujukou.github.io/purescript-backend-wasm/curry.png) |

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
