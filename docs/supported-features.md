# Supported Features

What PureScript currently compiles, and the WebAssembly (WAT) it lowers to.
This tracks the implemented slices (see the README roadmap); it is descriptive,
not a design decision.

- [Compilation model](#compilation-model-how-to-read-the-wat)
- [Top-level functions](#top-level-functions)
- [Algebraic data types and pattern matching](#algebraic-data-types-and-pattern-matching)
- [Scalar literals and literal patterns](#scalar-literals-and-literal-patterns)
- [Strings](#strings)
- [Arrays](#arrays)
- [Closures and Higher-order functions](#closures-and-higher-order-functions)
- [Function application, partial and over](#function-application-partial-and-over)
- [Recursive Let-bindings](#recursive-let-bindings)
- [Tail-call elimination](#tail-call-elimination)
- [Typeclasses](#typeclass-dictionaries)
- [Linking and reachability](#linking-and-reachability)
- [Records](#records)
- [Host Interface](#host-interface)

## Compilation model (how to read the WAT)

The uniform value representation is a **boxed `eqref`** (ADR 0001 / 0004): any
value *can* be held as an `eqref`, which is what makes parametric polymorphism and
the heap shapes below work. On top of that, two middle-end passes remove most of
the boxing in practice, so the emitted code is far leaner than a uniformly-boxed
model:

- **Dictionary elimination** (ADR 0005) inlines the type-class plumbing away, so
  `+` / `<` / `show` lower to direct calls to their `Int` / `String` / …
  implementations instead of method lookups
  through a dictionary closure.
- **Representation analysis** (ADR 0013) gives each binding, parameter, and result
  a concrete representation — a raw **`i32`** (`Int` / `Char`), a raw **`f64`**
  (`Number`), an **`i31ref`** (`Boolean`, and all-nullary enums such as
  `Ordering`), or the boxed **`eqref`** — and boxes **only at representation
  boundaries** (a *polymorphic* field, a polymorphic call, a closure capture, the
  host ABI). A constructor field whose type is a concrete `Int` / `Number` is
  stored **unboxed** in the constructor's struct (front B, read from the externs),
  so it is not a boundary. Monomorphic arithmetic and loops run allocation-free.

The recurring heap shapes — used *at* those boundaries — in the WAT:

- `(struct (field i32))` — a boxed `Int` (`$Int`). `struct.new` boxes, `struct.get 0`
  (after a `ref.cast`) unboxes; `Number` is the analogous `(struct (field f64))`.
- An ADT value is a **struct per constructor**: a tag-only base `$Data = (struct
  i32)` and, for each constructor, a subtype `(sub $Data (struct i32 <one field per
  ctor field>))` — the `i32` tag followed by each field at its own representation
  (`i32` / `f64` for a concrete scalar, `eqref` otherwise). A match casts to `$Data`
  to read the tag, then to the constructor's subtype to read a field. An enum-like
  ADT (**all constructors nullary**) is instead an allocation-free `i31ref` tag, and
  a nullary constructor of a mixed type (`Nil`, `Nothing`) is the shared tag-only
  base, allocated once.
- `(struct (field funcref) (field (ref …)))` — a closure (code pointer + a
  captured-environment array).
- Each exported function has a thin **`…$export` wrapper** with the host-facing
  `i32` signature; when the internal function already takes/returns `i32` (the
  common case after unboxing) the wrapper is a trivial pass-through.

Binaryen prunes unused types, so a small module shows only the shapes it needs.

## Top-level functions

```purs
import Prelude

addN :: Int -> Int -> Int
addN x y = x + y

five :: Int
five = addN 2 3
```

The `+` operator is defined in `Prelude` as a method of the **`Semiring`** type
class. Most of the type classes `Prelude` provides are given built-in compiler
support that inlines their methods down to machine **intrinsics**, and `Semiring`
is no exception — so `addN` compiles simply to `i32.add` (`*` and `-` reduce to
`i32.mul` / `i32.sub` the same way, through `Semiring` / `Ring`). On top of that the
representation analysis (ADR 0013) keeps `addN`'s parameters and result, and the
`Int` literals in `five`, as **raw `i32`** — so there is no `struct.new` / `ref.cast`
boxing anywhere — and `five` is a saturated direct (here tail-) `call`, its host
export wrapper a trivial pass-through. See [Typeclasses](#typeclass-dictionaries)
for how type-class methods are compiled. Emitted WAT:

```wat
(module
 (type $0 (func (param i32 i32) (result i32)))
 (type $1 (func (result i32)))
 (export "addN" (func $M.addN$export))
 (export "five" (func $M.five$export))
 (func $M.addN (type $0) (param $0 i32) (param $1 i32) (result i32)
  (local $2 i32)
  (local.set $2 (i32.add (local.get $0) (local.get $1)))   ;; raw i32 add — no boxing
  (local.get $2))
 (func $M.five (type $1) (result i32)
  (return_call $M.addN (i32.const 2) (i32.const 3)))        ;; direct (tail) call, raw i32 literals
 ;; host-facing i32 wrappers — trivial now that the callees are already i32
 (func $M.addN$export (type $0) (param $0 i32) (param $1 i32) (result i32)
  (call $M.addN (local.get $0) (local.get $1)))
 (func $M.five$export (type $1) (result i32)
  (call $M.five)))
```

So the host calls `five()` → `5`, `addN(2, 3)` → `5`.

## Algebraic data types and pattern matching

```purs
data OptInt = None | Some Int

orElse :: OptInt -> Int -> Int
orElse o d = case o of
  None -> d
  Some x -> x

someOrElse :: Int -> Int
someOrElse n = orElse (Some n) 0
```

A field-carrying constructor is a **struct subtype of the tag-only base `$Data =
(struct i32)`**: `Some`'s is `(sub $Data (struct i32 i32))` — the `i32` **tag**
(assigned by declaration order: `None` = 0, `Some` = 1) followed by its fields, each
at its own representation (`Some`'s `Int` is an **unboxed `i32`**; a polymorphic or
otherwise-boxed field would be `eqref`). Construction is a single `struct.new` of
that subtype. Two cases need no per-constructor struct (ADR 0013): an ADT whose
constructors are **all nullary** (e.g. `Ordering`, like `Boolean`) is just its tag as
an allocation-free `i31ref`; and a **nullary constructor of a mixed type** (`None`,
`Nil`) is the shared tag-only base `$Data`, allocated once. A `case` lowers to a
**decision tree** (`Lower.Match`). The example below is the simplest shape — one
scrutinee, flat constructor alternatives — an `if`/`else` chain that reads the tag by
casting the scrutinee to `$Data`; a constructor binder reads a matched field by
casting to that constructor's subtype and `struct.get`. An exhaustive match's
fall-through is `unreachable`.

The same compiler handles the general case: **several scrutinees at once**
(`case x, y of …`), **nested** constructor / literal / **array** (`[]`, `[a, b]`)
patterns, newtype erasure, and **guards** (a guarded alternative whose guards all
fail falls through to the subsequent alternatives). It picks a column, switches on
it with the fields projected into each branch, and recurses on the rest — see
[`Prelude` support](supported-features/Prelude-support.md) for the details and the
features this unlocks (derived `Eq`/`Ord`, `Generic` deriving).

```wat
;; types:  $Int  = (struct i32)                  a boxed Int
;;         $Data = (struct i32)                  the tag-only ADT base ($None is this, tag 0)
;;         $Some = (sub $Data (struct i32 i32))  Some: tag + an unboxed Int field
(func $M.orElse (param $0 eqref) (param $1 i32) (result i32)   ;; o, d
  (if (result i32)
   (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 0))   ;; tag o == 0 (None)?
   (then (local.get $1))                                                               ;; None -> d
   (else
    (if (result i32)
     (i32.eq (struct.get $Data 0 (ref.cast (ref $Data) (local.get $0))) (i32.const 1)) ;; tag o == 1 (Some)?
     ;; Some x -> x  : cast o to $Some and read field 1 (the unboxed Int)
     (then (struct.get $Some 1 (ref.cast (ref $Some) (local.get $0))))
     (else (unreachable))))))                                                          ;; exhaustive
(func $M.someOrElse (param $0 eqref) (result i32)   ;; n  (arrives boxed — someOrElse is an exported entry)
  (return_call $M.orElse
   ;; Some n  — one struct.new of $Some: tag 1, the field stored as a raw i32
   (struct.new $Some (i32.const 1) (struct.get $Int 0 (ref.cast (ref $Int) (local.get $0))))
   (i32.const 0)))                                  ;; orElse (Some n) 0
```

A nullary constructor is just the shared tag-only base (`None` is `struct.new $Data
(i32.const 0)`, allocated once), and binders at other positions read the
corresponding struct field — e.g. `case Triple a b c of Triple _ _ z` reads `z` with
`(struct.get $Triple 3 …)` (field 3 = the tag plus the third constructor field).

## Scalar literals and literal patterns

```purs
classify :: Int -> Int
classify n = case n of
  0 -> 100
  7 -> 700
  _ -> 999

isZero :: Int -> Int
isZero n = if eqI n 0 then 10 else 20    -- eqI : Int -> Int -> Boolean (intrinsic)
```

Beyond `Int`, the scalar representations are: **`Char`** shares `Int`'s
`(struct i32)` (its code point); **`Number`** is `$Num = (struct f64)`;
**`Boolean`** is an **`i31ref`** (`true` = 1, `false` = 0 — no allocation),
per ADR 0001. Matching on a **literal** (an `Int`/`Char`/`Number`/`Boolean`
pattern, including the `case` an `if` desugars to) compiles to a decision tree of
**value-equality tests** — not an ADT tag read: the scrutinee is unboxed and
compared (`i32.eq` for `Int`/`Char`, `f64.eq` for `Number`, `i31.get_s` + `i32.eq`
for `Boolean`). The catch-all (`_`/var) arm is the `else`; an exhausted match with
no catch-all traps.

```wat
;; classify: a chain of `if (n == k) … else …`, the `_` arm as the final else
(func $M.classify (param $0 eqref) (result eqref)   ;; n
  (if (result eqref)
   (i32.eq (struct.get $0 0 (ref.cast (ref $0) (local.get $0))) (i32.const 0))  ;; n == 0?
   (then (struct.new $0 (i32.const 100)))
   (else
    (if (result eqref)
     (i32.eq (struct.get $0 0 (ref.cast (ref $0) (local.get $0))) (i32.const 7)) ;; n == 7?
     (then (struct.new $0 (i32.const 700)))
     (else (struct.new $0 (i32.const 999)))))))                                  ;; _ -> 999
```

`isZero` produces a `Boolean` internally (`eqI` → `ref.i31` of an `i32.eq`) and
matches it: each arm tests `(i32.eq (i31.get_s (ref.cast i31ref scrut)) k)`. A
`Number` match tests `(f64.eq (struct.get $Num 0 (ref.cast (ref $Num) scrut)) k)`.

## Strings

```purs
foreign import concatS :: String -> String -> String   -- mapped to the StrConcat intrinsic
foreign import lenS :: String -> Int                    -- StrLen
foreign import eqS :: String -> String -> Boolean       -- StrEq

greetingLen :: Int -> Int
greetingLen _ = lenS (concatS "Hello, " "world!")       -- 13

matchHi :: Int -> Int
matchHi _ = case concatS "h" "i" of { "hi" -> 1; _ -> 0 }   -- 1
```

A `String` is `$Str = (struct (ref $Bytes))` with `$Bytes = (array (mut i8))`,
holding the string's **UTF-8** bytes (ADR 0001). A literal is built by
`array.new_fixed` of its bytes wrapped in a `struct.new $Str`; the encoder runs at
compile time, so a multibyte code point becomes its several bytes (and `lenS`
counts *bytes*, not UTF-16 code units — the documented divergence from
`Data.String.CodeUnits`). The string operations are ADR 0002 tier-2 runtime
functions, shared and emitted once:

- **`lenS`** (`StrLen`) is inline: `(array.len (struct.get $Str 0 (ref.cast (ref $Str) s)))`, boxed.
- **`concatS`** (`StrConcat`) calls `$rt.strConcat`, which `array.new`s a byte
  array of the combined length and `array.copy`s both halves in.
- **`eqS`** (`StrEq`) and **string literal patterns** both call `$rt.strEq`, a
  length check followed by a byte-by-byte compare returning an `i32` `1`/`0`
  (`eqS` boxes it as an `i31` Boolean; a pattern uses it directly as the `if`
  condition).

```wat
;; types: $Bytes = (array (mut i8))   $Str = (struct (ref $Bytes))
;; "hi" literal:
(struct.new $Str (array.new_fixed $Bytes 2 (i32.const 104) (i32.const 105)))
;; lenS s:
(struct.new $Int (array.len (struct.get $Str 0 (ref.cast (ref $Str) <s>))))
;; concatS a b  /  eqS a b:
(call $rt.strConcat <a> <b>)
(ref.i31 (call $rt.strEq <a> <b>))             ;; the i32 0/1 boxed as an i31 Boolean
```

## Arrays

```purs
foreign import lengthA :: forall a. Array a -> Int        -- ArrayLength
foreign import indexA :: forall a. Array a -> Int -> a    -- ArrayIndex

nums :: Array Int
nums = [ 10, 20, 30 ]

sumFirstTwo :: Int -> Int
sumFirstTwo _ = intAdd (indexA nums 0) (indexA nums 1)      -- 30
```

An `Array` is the **bare `$Vals = (array (mut eqref))`** — the same heap type ADT
fields, record values, and closure environments already use — so there is no new
type. A literal is one `array.new_fixed $Vals [<boxed elements>]`; `lengthA` is
`array.len` (boxed), and `indexA` is `array.get` (the element is already an
`eqref`, so nothing is unboxed). Elements being `eqref` is what lets arrays nest
(`Array (Array Int)`) uniformly.

```wat
;; [10, 20, 30]
(array.new_fixed $Vals 3 (struct.new $Int (i32.const 10))
                         (struct.new $Int (i32.const 20))
                         (struct.new $Int (i32.const 30)))
;; lengthA xs  /  indexA xs i
(struct.new $Int (array.len (ref.cast (ref $Vals) <xs>)))
(array.get $Vals (ref.cast (ref $Vals) <xs>) <unbox i>)
```

## Closures and higher-order functions

```purs
foreign import intAdd :: Int -> Int -> Int

applyTwice :: (Int -> Int) -> Int -> Int
applyTwice f x = f (f x)

twiceAdd :: Int -> Int -> Int
twiceAdd k x = applyTwice (\y -> intAdd k y) x
```

A closure is `(struct funcref (ref env))`: a **code pointer** plus a captured-
environment array. A lambda is lambda-lifted to a top-level code function whose
*first* parameter is its own closure (so it can read captures from the env);
`twiceAdd` builds the closure for `\y -> intAdd k y`, capturing `k` in the env.
Applying an *unknown* function value (here `applyTwice`'s parameter `f`) loads
its code pointer and uses `call_ref`, passing the closure itself as the first
argument (eval/apply, ADR 0003).

```wat
;; types: $1 = (array (mut eqref))                         env array
;;        $2 = (struct (field funcref) (field (ref $1)))   closure = code ptr + env
;;        $3 = (func (param (ref $2) eqref) (result eqref)) code signature
(func $M.twiceAdd (param $0 eqref) (param $1 eqref) (result eqref)   ;; k, x
  (local $2 eqref) (local $3 eqref)
  ;; (\y -> intAdd k y) : closure over code $code0, capturing k in env slot 0
  (local.set $2 (struct.new $2 (ref.func $M.$code0) (array.new_fixed $1 1 (local.get $0))))
  ;; applyTwice is known & saturated -> direct call
  (local.set $3 (call $M.applyTwice (local.get $2) (local.get $1)))
  (local.get $3))
(func $M.applyTwice (param $0 eqref) (param $1 eqref) (result eqref)   ;; f, x
  (local $2 eqref) (local $3 eqref)
  ;; f x  — f is unknown: load f's code ptr, call_ref with f as the closure arg
  (local.set $2 (call_ref $3 (ref.cast (ref $2) (local.get $0)) (local.get $1)
                  (ref.cast (ref $3) (struct.get $2 0 (ref.cast (ref $2) (local.get $0))))))
  ;; f (f x)  — again, on the previous result
  (local.set $3 (call_ref $3 (ref.cast (ref $2) (local.get $0)) (local.get $2)
                  (ref.cast (ref $3) (struct.get $2 0 (ref.cast (ref $2) (local.get $0))))))
  (local.get $3))
;; the lifted body of (\y -> intAdd k y): k lives in env slot 0, y is the argument
(func $M.$code0 (param $0 (ref $2)) (param $1 eqref) (result eqref)
  (local $2 eqref)
  (local.set $2 (struct.new $0 (i32.add
    (struct.get $0 0 (ref.cast (ref $0) (array.get $1 (struct.get $2 1 (local.get $0)) (i32.const 0)))) ;; unbox k
    (struct.get $0 0 (ref.cast (ref $0) (local.get $1))))))                                             ;; unbox y
  (local.get $2))
```

## Function application, partial and over

```purs
addN :: Int -> Int -> Int
addN x y = intAdd x y

add3 :: Int -> Int
add3 = addN 3       -- partial application of a known 2-arg function (a PAP)

add3of :: Int -> Int
add3of n = add3 n   -- over-applies the (nullary) PAP value
```

`addN 3` supplies only one of `addN`'s two arguments. Since `addN` is known, it
is **eta-expanded** into a chain of one-argument closures (`$code4`/`$code5`):
applying `$code4` to `3` returns a closure (`$code5`) that has captured `3` and
still awaits the second argument. `add3of n = add3 n` then **over-applies** that
PAP value — it computes `add3`, then supplies the remaining argument with
`call_ref`. (The same `call_ref` machinery covers multi-argument application of
an unknown value: `f x y` becomes a chain of single-argument `call_ref`s.)

```wat
;; types: $0 = (array (mut eqref))   $1 = closure   $2 = boxed Int
;;        $4 = (func (param (ref $1) eqref) (result eqref))   code signature
(func $M.add3 (result eqref)
  (local $0 eqref) (local $1 eqref)
  ;; eta-expansion closure for addN (no captures yet), then apply it to 3
  (local.set $0 (struct.new $1 (ref.func $M.$code4) (array.new_fixed $0 0)))
  (local.set $1 (call_ref $4 (ref.cast (ref $1) (local.get $0)) (struct.new $2 (i32.const 3))
                  (ref.cast (ref $4) (struct.get $1 0 (ref.cast (ref $1) (local.get $0))))))
  (local.get $1))   ;; result: a closure still awaiting one argument
(func $M.add3of (param $0 eqref) (result eqref)   ;; n
  (local $1 eqref) (local $2 eqref)
  (local.set $1 (call $M.add3))                    ;; the PAP value (a closure)
  ;; over-apply it: supply the remaining argument via call_ref
  (local.set $2 (call_ref $4 (ref.cast (ref $1) (local.get $1)) (local.get $0)
                  (ref.cast (ref $4) (struct.get $1 0 (ref.cast (ref $1) (local.get $1))))))
  (local.get $2))
;; eta-expansion of the 2-arg addN into one-arg closures:
;; $code4 captures the 1st argument and returns a closure awaiting the 2nd
(func $M.$code4 (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (local $2 eqref)
  (local.set $2 (struct.new $1 (ref.func $M.$code5) (array.new_fixed $0 1 (local.get $1))))
  (local.get $2))
;; $code5 has both arguments (one captured, one passed) and makes the real call
(func $M.$code5 (param $0 (ref $1)) (param $1 eqref) (result eqref)
  (local $2 eqref)
  (local.set $2 (call $M.addN
    (array.get $0 (struct.get $1 1 (local.get $0)) (i32.const 0))   ;; captured 1st arg (3)
    (local.get $1)))                                               ;; 2nd arg
  (local.get $2))
```

## Recursive Let-bindings

Top-level mutual recursion needs nothing special — each call is a saturated,
known, direct `call` (e.g. `isEvenN`/`isOddN` calling each other). A
self-recursive local `let` / `where` function (the `where go acc = … go acc'`
loop idiom) is **lambda-lifted to a top-level supercombinator** (`Lower.LambdaLift`):
its captured free variables become leading parameters, references to it become
that top-level name partially applied to the captures, and its saturated self-call
is then a direct `RCallKnown`. That matters for tail-call elimination (below) — a
closure self-call would not be eliminated. The hard case is **local mutual
recursion**, shown here:

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

## Tail-call elimination

```purs
import Prelude

-- iterative Fibonacci: `go` is a tail-recursive accumulator loop
fib :: Int -> Int
fib n =
  let
    go a b k =
      if k == 1 then a
      else go b (a + b) (k - 1)
  in
    go 1 1 n
```

A **direct call in tail position** — a `RCallKnown` whose result is returned
immediately — is emitted as a wasm `return_call` (the `TailCall` feature) rather
than a `call` followed by a return. The engine replaces the current frame instead
of growing the stack, so a tail-recursive chain runs in **constant stack**:
`fib 1_000_000` returns instead of overflowing (~10⁶ frames otherwise). This covers
top-level self- and mutual tail recursion, and tail calls to any other top-level
function.

The catch is that `go` above is a `where`/`let`-bound self-recursive helper — a
*closure* self-call, which would be a `call_ref` that `return_call` does **not**
reach (binaryen.js does not expose `return_call_ref`). The lambda-lifting pass
bridges that: hoisting `go` to a top-level supercombinator turns its self-call into
a direct `RCallKnown`, so it becomes an ordinary `return_call` — and since the
representation analysis keeps `a`/`b`/`k` as raw `i32`, the tail reads
`(return_call $go b (i32.add a b) (i32.sub k 1))`. `fib`'s `go` therefore loops
~10⁶ times in constant stack.

Not covered: tail calls to an *unknown* closure value (a function argument), which
would need `return_call_ref`.

## Typeclass dictionaries

```purs
class Addable a where
  plus :: a -> a -> a
  nil :: a

instance addableInt :: Addable Int where
  plus x y = intAdd x y
  nil = 0

double :: forall a. Addable a => a -> a
double x = plus x x

doubleInt :: Int -> Int
doubleInt n = double n
```

**Dictionary elimination (ADR 0005) removes the dictionary wherever the instance
is statically known — the common case.** Here `doubleInt` carries no dictionary at
all: it lowers to a direct `intAdd(n, n)` (via the inlined Int-specialisation
`double1 = \x -> intAdd(x, x)`), with no `$Rec` allocation, no label search, and
no `plus` closure. The representation described below is what *remains* for
genuinely **polymorphic, dictionary-passing** code — `double` called at a type not
known at compile time — and is also how records are represented in general.

In CoreFn a class is a **newtype dictionary constructor** wrapping a record of
its methods, an instance is a top-level value (a record), and a method is an
accessor `\dict -> case dict of Addable$Dict v -> v.plus`. So dictionaries are
**records**, and — since a record's fields are not known at a projection site
(CoreFn is type-erased) — they are represented as a **label-map** that is
searched at runtime (ADR 0001 / 0007): a `$Rec` struct of parallel arrays, the
labels **interned to `i32` ids** (no string runtime yet) and the values. The
newtype constructor and its `case` unwrap are erased; `double` receives the
dictionary and passes it on (dictionary-passing).

```wat
;; types: $0 = boxed Int   $1 = (array (mut eqref))   $2 = closure
;;        $4 = (array i32)                        interned label ids
;;        $5 = (struct (ref $4) (ref $1))         a record = label ids + values
;; instance addableInt : the record { nil, plus } (labels sorted: nil=0, plus=1)
(func $M.addableInt (result eqref)
  (local $0 eqref) (local $1 eqref)
  (local.set $0 (struct.new $2 (ref.func $M.$code1) (array.new_fixed $1 0)))   ;; the `plus` closure
  (local.set $1 (struct.new $5
    (array.new_fixed $4 2 (i32.const 0) (i32.const 1))                         ;; label ids [nil, plus]
    (array.new_fixed $1 2 (struct.new $0 (i32.const 0)) (local.get $0))))      ;; values   [0,   plus]
  (local.get $1))
;; method `plus` : project label id 1 from the dictionary (a label search)
(func $M.plus (param $0 eqref) (result eqref)
  (local $1 eqref)
  (local.set $1 (call $rt.proj (local.get $0) (i32.const 1)))
  (local.get $1))
```

Projection is one shared runtime helper — `$rt.proj(rec, targetId)` linearly
searches the label-id array and returns the parallel value:

```wat
(func $rt.proj (param $0 eqref) (param $1 i32) (result eqref)
  (local $2 i32)                                        ;; index
  (block $found (result eqref)
    (local.set $2 (i32.const 0))
    (loop $loop
      ;; if ids[i] == target  ->  return vals[i]
      (if (i32.eq (array.get $4 (struct.get $5 0 (ref.cast (ref $5) (local.get $0))) (local.get $2))
                  (local.get $1))
        (then (br $found (array.get $1 (struct.get $5 1 (ref.cast (ref $5) (local.get $0))) (local.get $2)))))
      (local.set $2 (i32.add (local.get $2) (i32.const 1)))
      (br_if $loop (i32.lt_u (local.get $2)
                             (array.len (struct.get $5 0 (ref.cast (ref $5) (local.get $0))))))
      (unreachable))))                                  ;; label absent — impossible by construction
```

When the dictionary genuinely must be passed (polymorphic code), `plus` is
dispatched through this label search. The same search serves **superclass
access**: a superclass dictionary is just
another (thunked) field `<SuperclassName><n>` (e.g. `Base0`), read by the same
`$rt.proj` and then applied — no class/type information needed, so arbitrarily
deep hierarchies work. (Positional/tuple dictionaries would be faster but need
type information; deferred to a later optimization — ADR 0007.)

### Dictionary elimination (ADR 0005, implemented)

The middle end runs a whole-program simplifier that inlines the type-class
plumbing — the dictionary constructors, the method accessors, the instance
records, and the derived helpers (`lessThan`, `negate`, …) — to a fixed point,
collapsing `accessor(instance)` down to the underlying implementation. Wherever an
instance is statically known, this removes the dictionary value, its `$Rec`
allocation, and the `$rt.proj` label search **entirely**: `plus addableInt x y`
becomes `intAdd(x, y)`, and `doubleInt` above lowers to a direct `intAdd(n, n)`.
Combined with representation analysis (ADR 0013) the operands stay raw `i32`, so
the dispatch hot path that this section's machinery describes simply does not run
for monomorphic code. The bench suite (`bench/`) shows the effect — arithmetic and
comparison kernels run several times faster than the equivalent optimized JS.

What remains: a *genuinely* polymorphic dictionary (passed at a type unknown at
compile time) still uses the runtime representation above, and such a dictionary
CAF is currently a nullary function re-evaluated per reference rather than memoized
to a module global (the evaluate-once sharing of **ADR 0006**, still proposed).
That is now a narrow case — most dictionaries never survive elimination.

## Linking and reachability

A program spans more than one module — the user's code plus the `Prelude` modules
it uses. Two pieces of the build (ADR 0009) make linking them into one wasm
practical:

- **Multi-module linking** — every reached module is linked into a single wasm,
  with cross-module references resolved by qualified name.
- **Function-level reachability** — only the functions actually reached from the
  entry are lowered. A `Prelude` module like `Data.Semiring` defines many instances
  (`Semiring` for records, functions, `Proxy`, …, some using constructs not yet
  supported); none are visited unless reached, so a small program pulls in only the
  handful of `Prelude` functions it needs (and never trips over the unsupported
  ones it doesn't touch).

A large part of `Prelude` works as expected; per-feature notes are in
[this document](./supported-features/Prelude-support.md).

## Records

```purs
type Point = { x :: Int, y :: Int }

mk :: Int -> Int -> Point
mk x y = { x, y }                        -- construction

getX :: Point -> Int
getX p = p.x                             -- field access

moveX :: Point -> Point
moveX p = p { x = intAdd p.x 5 }           -- update

patX :: Point -> Int
patX { x } = x                           -- pattern destructuring
```

Ordinary records use the **same label-map** as type-class dictionaries (which are
records in CoreFn) — there is no separate representation. So construction
(`RMkRecord`) and field access (`RProjLabel`) already work from the dictionary
support; records add two more forms:

- **Update** `r { x = v }` rebuilds the record: updated fields take their new
  values, and the untouched fields — which purs lists in the CoreFn `copy` set for
  a monomorphic record — are projected out of the original and copied in. So it is
  just an `RMkRecord` over `(updated value | RProjLabel original)` per label; no
  new codegen.
- **Patterns** `\{ x } -> …` are a single always-matching destructure: each field
  sub-binder is bound to its `RProjLabel` of the scrutinee (no `Switch`).

`Record.Unsafe`'s **dynamic-`String`-key** operations (`unsafeGet` / `unsafeSet` /
`unsafeHas` / `unsafeDelete`) are now supported. Labels are interned to `i32` ids at
compile time, so a runtime `String` key (e.g. a `reflectSymbol` result) is bridged by
the emitted **`internStr`** resolver — the program's label table as an `if strEq key
"label" then <id> …` chain — after which the id-keyed helpers apply: `$rt.proj`
(read) and `$rt.recHas` / `$rt.recSet` / `$rt.recDelete` (rebuild the sorted parallel
id/value arrays). This is what the real `Eq` / `Show` / `Ord` instances for records
run on (see `Prelude` support).

Still deferred: **polymorphic update** of an open row (`r { x = v }` with `copy`
absent — the unknown extra fields need a runtime copy).

## Host interface

Every exported function gets a thin `…$export` wrapper with the host-facing
`i32` signature (visible in the first example): it boxes the `i32` arguments,
calls the internal `eqref` function, and unboxes the `i32` result. Today the
host boundary is `Int`-typed; a binding whose value is not an `Int` (an instance
dictionary, say) still gets a wrapper, but it traps if actually called as `i32`.
