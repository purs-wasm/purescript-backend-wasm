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

- [x] [Higher-order functions](./docs/supported-features.md#closures-and-higher-order-functions) with [full-support for partial/over application](./docs/supported-features.md#function-application-partial-and-over)
- [x] [strings](./docs/supported-features.md#strings), [arrays](./docs/supported-features.md#arrays) and [records](./docs/supported-features.md#records)
- [x] [ADT and pattern matching](./docs/supported-features.md#algebraic-data-types-and-pattern-matching)
- [x] [Recursive let-bindings](./docs/supported-features.md#recursive-let-bindings)
- [x] [Basic typeclass resolution](./docs/supported-features.md#typeclass-dictionaries-not-optimized) (no cyclic dependencies like `Effect`'s Functor/Applicative/Monad instances')
- [ ] `Prelude` builtin support ... *WIP*
- [ ] User-defined FFI (beyond the built-in intrinsics table)
- [ ] Special compiler support for `Effect` and `ST` monad
- [ ] Optimizations: unboxing, arity raising / uncurrying, nominal record layout,
      unboxed/immediate enum constructors (OCaml-style constant constructors)
- [ ] Multiple platform support (browser/node/native)

## Example

```purescript
module Example.Fib where

import Prelude

fib :: Int -> Int
fib n' =
  let
    decr = (_ - 1)
    go a b k =
      if k == 1 then a
      else go b (a + b) (decr k)
  in
    go 1 1 n'
```

compiles to the wasm (wat format) below. The dictionary plumbing that the real
`Prelude` `(+)` / `(-)` / `(==)` pull in is elided to keep the focus on `fib`
itself; only the closure-converted `fib` and its export wrapper are shown.

```wat
(module
 (type $0 (array (mut eqref)))
 (type $1 (struct (field funcref) (field (ref $0))))
 (type $2 (func (param (ref $1) eqref) (result eqref)))
 (type $3 (struct (field i32)))
 (type $4 (array i32))
 (type $5 (struct (field (ref $4)) (field (ref $0))))
 (type $6 (func (result eqref)))
 (type $7 (func (result i32)))
 (type $8 (func (param (ref $5) i32) (result eqref)))
 (type $9 (func (result (ref $5))))
 (type $10 (func (param i32) (result i32)))
 (elem declare func $Example.Fib.$code9 $Example.Fib.$code10 $Example.Fib.$code11 $Example.Fib.$code12)
 (export "fib" (func $Example.Fib.fib$export))

 ;; --- elided: Prelude dictionary plumbing for (+) / (-) / (==) ---
 ;;   $rt.proj (runtime label search), Data.Semiring.semiringInt,
 ;;   Data.{Eq,Ring,Semiring}.$code*, and the Example.Fib.{sub,eq,add}
 ;;   dictionary-projection thunks (plus their export wrappers).

 (func $Example.Fib.$code9 (type $2) (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (call_ref $2
   (local.tee $0
    (ref.cast (ref $1)
     (call_ref $2
      (local.tee $0
       (ref.cast (ref $1)
        (call $Example.Fib.sub)))
      (local.get $1)
      (ref.cast (ref $2)
       (struct.get $1 0
        (local.get $0))))))
   (struct.new $3
    (i32.const 1))
   (ref.cast (ref $2)
    (struct.get $1 0
     (local.get $0)))))
 (func $Example.Fib.$code12 (type $2) (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (local $2 (ref $1))
  (local $3 eqref)
  (if (result eqref)
   (i32.eq
    (i31.get_s
     (ref.cast i31ref
      (call_ref $2
       (local.tee $2
        (ref.cast (ref $1)
         (call_ref $2
          (local.tee $2
           (ref.cast (ref $1)
            (call $Example.Fib.eq)))
          (local.get $1)
          (ref.cast (ref $2)
           (struct.get $1 0
            (local.get $2))))))
       (struct.new $3
        (i32.const 1))
       (ref.cast (ref $2)
        (struct.get $1 0
         (local.get $2))))))
    (i32.const 1))
   (then
    (array.get $0
     (struct.get $1 1
      (local.get $0))
     (i32.const 0)))
   (else
    (local.set $3
     (call_ref $2
      (local.tee $2
       (ref.cast (ref $1)
        (call_ref $2
         (local.tee $2
          (ref.cast (ref $1)
           (call $Example.Fib.add)))
         (array.get $0
          (struct.get $1 1
           (local.get $0))
          (i32.const 0))
         (ref.cast (ref $2)
          (struct.get $1 0
           (local.get $2))))))
      (array.get $0
       (struct.get $1 1
        (local.get $0))
       (i32.const 2))
      (ref.cast (ref $2)
       (struct.get $1 0
        (local.get $2)))))
    (local.set $1
     (call_ref $2
      (local.tee $2
       (ref.cast (ref $1)
        (array.get $0
         (struct.get $1 1
          (local.get $0))
         (i32.const 3))))
      (local.get $1)
      (ref.cast (ref $2)
       (struct.get $1 0
        (local.get $2)))))
    (call_ref $2
     (local.tee $0
      (ref.cast (ref $1)
       (call_ref $2
        (local.tee $0
         (ref.cast (ref $1)
          (call_ref $2
           (local.tee $2
            (ref.cast (ref $1)
             (array.get $0
              (struct.get $1 1
               (local.get $0))
              (i32.const 1))))
           (array.get $0
            (struct.get $1 1
             (local.get $0))
            (i32.const 2))
           (ref.cast (ref $2)
            (struct.get $1 0
             (local.get $2))))))
        (local.get $3)
        (ref.cast (ref $2)
         (struct.get $1 0
          (local.get $0))))))
     (local.get $1)
     (ref.cast (ref $2)
      (struct.get $1 0
       (local.get $0)))))))
 (func $Example.Fib.$code11 (type $2) (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (struct.new $1
   (ref.func $Example.Fib.$code12)
   (array.new_fixed $0 4
    (array.get $0
     (struct.get $1 1
      (local.get $0))
     (i32.const 0))
    (array.get $0
     (struct.get $1 1
      (local.get $0))
     (i32.const 1))
    (local.get $1)
    (array.get $0
     (struct.get $1 1
      (local.get $0))
     (i32.const 2)))))
 (func $Example.Fib.$code10 (type $2) (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (struct.new $1
   (ref.func $Example.Fib.$code11)
   (array.new_fixed $0 3
    (local.get $1)
    (local.get $0)
    (array.get $0
     (struct.get $1 1
      (local.get $0))
     (i32.const 0)))))
 (func $Example.Fib.fib$export (type $10) (param $0 i32) (result i32)
  (local $1 (ref $1))
  (struct.get $3 0
   (ref.cast (ref $3)
    (call_ref $2
     (local.tee $1
      (ref.cast (ref $1)
       (call_ref $2
        (local.tee $1
         (ref.cast (ref $1)
          (call $Example.Fib.$code10
           (struct.new $1
            (ref.func $Example.Fib.$code10)
            (array.new_fixed $0 1
             (struct.new $1
              (ref.func $Example.Fib.$code9)
              (array.new_fixed $0 0))))
           (struct.new $3
            (i32.const 1)))))
        (struct.new $3
         (i32.const 1))
        (ref.cast (ref $2)
         (struct.get $1 0
          (local.get $1))))))
     (struct.new $3
      (local.get $0))
     (ref.cast (ref $2)
      (struct.get $1 0
       (local.get $1))))))))
```
