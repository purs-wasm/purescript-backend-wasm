# Supported Features

What PureScript currently compiles, and the WebAssembly (WAT) it lowers to.
This tracks the implemented slices (see the README roadmap); it is descriptive,
not a design decision.

## Compilation model (how to read the WAT)

Per ADR 0001 / 0004, every runtime value is a **boxed `eqref`**, and internal
functions take and return `eqref`. The recurring shapes in the WAT:

- `(struct (field i32))` — a boxed `Int`. `struct.new` boxes, `struct.get 0`
  (after a `ref.cast`) unboxes.
- `(struct (field i32) (field (ref …)))` — an ADT (`tag` + a field array).
- `(struct (field funcref) (field (ref …)))` — a closure (code pointer + a
  captured-environment array).
- Each exported function has a thin **`…$export` wrapper** with the host-facing
  `i32` signature: it boxes the `i32` arguments, calls the internal `eqref`
  function, and unboxes the result.

Binaryen prunes unused types, so a module that only uses `Int` shows just the
boxed-`Int` struct.

## Top-level functions and full (saturated) application

```purs
foreign import addI :: Int -> Int -> Int

addN :: Int -> Int -> Int
addN x y = addI x y

five :: Int
five = addN 2 3
```

`addI` is a module-local foreign primitive mapped to the `i32.add` intrinsic
(ADR 0002). `five` is a saturated call to `addN`, which lowers to a direct
`call`. Full emitted WAT:

```wat
(module
 (type $0 (struct (field i32)))
 (type $1 (func (param eqref eqref) (result eqref)))
 (type $2 (func (result eqref)))
 (type $3 (func (param i32 i32) (result i32)))
 (type $4 (func (result i32)))
 (export "addN" (func $M.addN$export))
 (export "five" (func $M.five$export))
 (func $M.addN (type $1) (param $0 eqref) (param $1 eqref) (result eqref)
  (local $2 eqref)
  (local.set $2
   (struct.new $0                                  ;; box the i32 result
    (i32.add
     (struct.get $0 0 (ref.cast (ref $0) (local.get $0)))   ;; unbox x
     (struct.get $0 0 (ref.cast (ref $0) (local.get $1))))))  ;; unbox y
  (local.get $2))
 (func $M.five (type $2) (result eqref)
  (local $0 eqref)
  (local.set $0
   (call $M.addN
    (struct.new $0 (i32.const 2))                  ;; box 2
    (struct.new $0 (i32.const 3))))                ;; box 3
  (local.get $0))
 ;; host-facing i32 wrappers
 (func $M.addN$export (type $3) (param $0 i32) (param $1 i32) (result i32)
  (struct.get $0 0
   (ref.cast (ref $0)
    (call $M.addN (struct.new $0 (local.get $0)) (struct.new $0 (local.get $1))))))
 (func $M.five$export (type $4) (result i32)
  (struct.get $0 0 (ref.cast (ref $0) (call $M.five)))))
```

So the host calls `five()` → `5`, `addN(2, 3)` → `5`.

## Mutually-recursive local bindings (`let rec`)

```purs
data Nat = Z | S Nat

parity :: Nat -> Int
parity n =
  let
    ev m = case m of
      Z -> 1
      S k -> od k
    od m = case m of
      Z -> 0
      S k -> ev k
  in
    ev n
```

`ev` and `od` are local closures that reference each other, so they are compiled
with **knot-tying** (ADR 0003): both closures are allocated first with a
placeholder in the environment slot that will hold the sibling, then those slots
are back-patched with `array.set` once both exist. `ev`/`od` themselves are
lifted to top-level code functions (`$code0`/`$code1`, omitted here). The body of
`parity`, abbreviated:

```wat
;; types: $0 = (array (mut eqref))  env array
;;        $1 = (struct funcref (ref $0))   closure
(func $M.parity (param $0 eqref) (result eqref)
  (local $1 eqref) (local $2 eqref) (local $3 eqref)
  ;; allocate both members; the sibling's env slot is a placeholder box(0) for now
  (local.set $1 (struct.new $1 (ref.func $M.$code0)
                  (array.new_fixed $0 1 (struct.new $3 (i32.const 0)))))
  (local.set $2 (struct.new $1 (ref.func $M.$code1)
                  (array.new_fixed $0 1 (struct.new $3 (i32.const 0)))))
  ;; knot-tying: back-patch each member's env slot to point at its sibling
  (array.set $0 (struct.get $1 1 (ref.cast (ref $1) (local.get $1))) (i32.const 0) (local.get $2))
  (array.set $0 (struct.get $1 1 (ref.cast (ref $1) (local.get $2))) (i32.const 0) (local.get $1))
  ;; ev n  — call_ref through ev's stored code pointer (ev is local $2 here)
  (local.set $3 (call_ref $4 (ref.cast (ref $1) (local.get $2)) (local.get $0)
                   (ref.cast (ref $4) (struct.get $1 0 (ref.cast (ref $1) (local.get $2))))))
  (local.get $3))
```

## Currently supported

- Top-level function definitions; saturated calls (direct `call`).
- `Int` literals and arithmetic via module-local `foreign import` primitives
  mapped to `i32` intrinsics (`addI`/`mulI`/`subI`). *(Not yet the real Prelude
  `+`/`*`, which go through type-class dictionaries — see below.)*
- Algebraic data types: construction, and **single-scrutinee, unguarded**
  pattern matching with constructor binders (`Var`/wildcard sub-binders).
- Closures: lambdas with free-variable capture; higher-order functions;
  **partial application / over-application** and first-class function values;
  multi-argument application.
- Recursion: top-level mutual recursion, local self-recursion, and local mutual
  recursion (`let rec`, via knot-tying).
- Host interface: functions exported with an `Int` (`i32`) signature.

## Not yet supported

- Real Prelude **type classes / instance dictionaries** — so `+`, `*`, `show`,
  `==`, etc. through instances (the next milestone; dictionaries appear as
  recursive *value* groups and want a topological-sort + optimization pass).
- `Number`, `String`, `Char`, `Boolean` literals and operations; `Array`s;
  records.
- Multi-scrutinee `case`, guards, nested or literal binders.
- `Effect` and other effectful computation.
- Recursive non-function values (PureScript's `$runtime_lazy`).
