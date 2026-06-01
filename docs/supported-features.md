# Supported Features

What PureScript currently compiles, and the WebAssembly (WAT) it lowers to.
This tracks the implemented slices (see the README roadmap); it is descriptive,
not a design decision.

- [Compilation model](#compilation-model-how-to-read-the-wat)
- [Top-level functions](#top-level-functions)
- [Algebraic data types and single-scrutinee pattern matching](#algebraic-data-types-and-single-scrutinee-pattern-matching)
- [Scalar literals and literal patterns](#scalar-literals-and-literal-patterns)
- [Strings](#strings)
- [Arrays](#arrays)
- [Closures and Higher-order functions](#closures-and-higher-order-functions)
- [Function application, partial and over](#function-application-partial-and-over)
- [Recursive Let-bindings](#recursive-let-bindings)
- [Typeclasses (Not optimized!)](#typeclass-dictionaries-not-optimized)
- [Real Prelude operations (Semiring/Ring, Eq/Ord, HeytingAlgebra)](#real-prelude-operations-semiringring-eqord-heytingalgebra)
- [Records](#records)
- [Host Interface](#host-interface)

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

## Top-level functions

```purs
foreign import intAdd :: Int -> Int -> Int

addN :: Int -> Int -> Int
addN x y = intAdd x y

five :: Int
five = addN 2 3
```

`intAdd` is a module-local foreign primitive mapped to the `i32.add` intrinsic
(ADR 0002); `intMul`/`intSub` map to `i32.mul`/`i32.sub` the same way. `Int`
literals box an `i32.const`. `five` is a saturated call to `addN`, which lowers
to a direct `call`. Full emitted WAT:

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

## Algebraic data types and single-scrutinee pattern matching

```purs
data OptInt = None | Some Int

orElse :: OptInt -> Int -> Int
orElse o d = case o of
  None -> d
  Some x -> x

someOrElse :: Int -> Int
someOrElse n = orElse (Some n) 0
```

A value of an ADT is `(struct tag fields)`: an `i32` **constructor tag**
(assigned by declaration order — `None` = 0, `Some` = 1) plus a boxed-`eqref`
**field array**. Construction is `struct.new` over an `array.new_fixed` of the
fields. A single-scrutinee `case` lowers to a **decision tree**: an `if`/`else`
chain that compares the scrutinee's tag against each constructor; a constructor
binder reads the matched fields out of the array with `array.get`. The match is
known to be exhaustive, so the final fall-through is `unreachable`.

```wat
;; types: $0 = (struct (field i32))                    boxed Int
;;        $1 = (array (mut eqref))                      field array
;;        $2 = (struct (field i32) (field (ref $1)))    an ADT: tag + fields
(func $M.orElse (param $0 eqref) (param $1 eqref) (result eqref)   ;; o, d
  (local $2 eqref)
  (if (result eqref)
   (i32.eq (struct.get $2 0 (ref.cast (ref $2) (local.get $0))) (i32.const 0))   ;; tag o == 0 (None)?
   (then (local.get $1))                                                         ;; None -> d
   (else
    (if (result eqref)
     (i32.eq (struct.get $2 0 (ref.cast (ref $2) (local.get $0))) (i32.const 1)) ;; tag o == 1 (Some)?
     (then
      ;; Some x -> x  : bind x = field 0 of o, then return it
      (local.set $2 (array.get $1 (struct.get $2 1 (ref.cast (ref $2) (local.get $0))) (i32.const 0)))
      (local.get $2))
     (else (unreachable))))))                                                    ;; exhaustive
(func $M.someOrElse (param $0 eqref) (result eqref)   ;; n
  (local $1 eqref) (local $2 eqref)
  ;; Some n  — construct: tag 1, one field
  (local.set $1 (struct.new $2 (i32.const 1) (array.new_fixed $1 1 (local.get $0))))
  ;; orElse (Some n) 0  — saturated direct call; the literal 0 is box(0)
  (local.set $2 (call $M.orElse (local.get $1) (struct.new $0 (i32.const 0))))
  (local.get $2))
```

A nullary constructor just has an empty field array (`None` is
`(struct.new $2 (i32.const 0) (array.new_fixed $1 0))`), and binders at other
positions read the corresponding index — e.g. `case Triple a b c of Triple _ _ z`
reads `z` with `(array.get $1 … (i32.const 2))`.

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
self-recursive local `let` recurs through its own closure parameter. The hard
case is **local mutual recursion**, shown here:

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

## Typeclass dictionaries (Not optimized!)

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

So `doubleInt(n)` → `2n`, dispatching `plus` through the dictionary. The same
label search serves **superclass access**: a superclass dictionary is just
another (thunked) field `<SuperclassName><n>` (e.g. `Base0`), read by the same
`$rt.proj` and then applied — no class/type information needed, so arbitrarily
deep hierarchies work. (Positional/tuple dictionaries would be faster but need
type information; deferred to a later optimization — ADR 0007.)

### Performance note: dictionaries are rebuilt on every use (no memoization)

`purs` already hoists an instance-specialized method to a module-level binding —
e.g. `doubleInt n = double n` becomes `double1 = double addableInt` plus
`doubleInt = \n -> double1 n`, so the specialization is named once rather than
repeated at each call site. We **preserve** that structure.

What we do **not** yet do is *memoize* it. A top-level value binding (a CAF — an
instance dictionary like `addableInt`, or a specialized method like `double1`)
compiles to a **nullary function**, and every reference to it is a fresh `call`.
So each `doubleInt(n)` re-runs `double1()` → `addableInt()`, which **re-allocates
the dictionary `$Rec` struct and its arrays and re-does the label projection**
every time. The JS backend's `const double1 = double(addableInt)` instead
evaluates once at module load and caches the value.

This is a real penalty on the dispatch hot path (allocation + search per call).
The fix is **ADR 0006** (compile acyclic CAFs to module globals initialized once),
which would give the same evaluate-once sharing as the JS `const`. Eliminating
the dictionary and projection altogether — `add dict x y → intAdd x y` — is the
separate, further optimization of **ADR 0005** (dictionary elimination). Both are
Proposed, not yet implemented.

## Real `Prelude` operations (`Semiring`/`Ring`, `Eq`/`Ord`, `HeytingAlgebra`)

```purs
import Prelude

poly :: Int -> Int -> Int
poly a b = a * a + b * b - a            -- real `+` / `*` / `-`, no foreign imports

cmp :: Int -> Int -> Int
cmp a b = if a == b then 0 else if a < b then -1 else 1   -- real `==` / `<`
```

`+` / `*` / `-` on `Int` go through the **real `Prelude`**, not hand-written
intrinsics. purs desugars them to the `Semiring` / `Ring` method accessors applied
to the `semiringInt` / `ringInt` instance dictionaries; those dictionaries (in
`Data.Semiring` / `Data.Ring`) are records whose `add` / `mul` / `sub` fields are
the `intAdd` / `intMul` / `intSub` **foreign** functions, which the intrinsics
table maps to `i32.add` / `i32.mul` / `i32.sub`. So the existing dictionary support
(above) plus those three intrinsics is all it takes — `poly` links the user module
with `Data.Semiring` / `Data.Ring` into one wasm and runs.

Two pieces of the build make this practical (ADR 0009):

- **Multi-module linking** — the modules are linked into a single wasm, with
  cross-module references resolved by qualified name.
- **Function-level reachability** — only the functions actually reached from the
  entry are lowered. A `Prelude` module like `Data.Semiring` defines many other
  instances (`Semiring` for records, functions, `Proxy`, …, some using constructs
  not yet supported); none are visited, because `poly` reaches only `semiringInt`,
  the `add`/`mul` accessors, and the `intAdd`/`intMul` intrinsics.

**`Eq` / `Ord`** work the same way. `==` is the `Eq` dictionary's `eqIntImpl`
(→ `i32.eq`). `Ord`'s `compare` is `ordIntImpl LT EQ GT` — an intrinsic that
selects the `Ordering` ADT (`LT`/`EQ`/`GT`, an ordinary data type) by a signed
`i32` comparison; `<` / `>` / `<=` derive from `compare` via a constructor match
(which is why a `case` on constructors now also takes a catch-all `_` default).

**Boolean algebra** (`HeytingAlgebra`) is the same once more: `&&` / `||` / `not`
are the `conj` / `disj` / `not` accessors on `heytingAlgebraBoolean`, whose fields
are the `boolConj` / `boolDisj` / `boolNot` foreigns — `i32.and` / `i32.or` /
`i32.eqz` on the unboxed `i31` Boolean bits. (`&&` and `||` are the strict Prelude
operators, so both operands are evaluated — no short-circuiting.)

**`Number` arithmetic** likewise: `+` / `*` / `-` (`semiringNumber` / `ringNumber`)
and `/` (`euclideanRingNumber`) map to the `numAdd` / `numMul` / `numSub` / `numDiv`
foreigns — `f64.add` / `sub` / `mul` / `div` on the unboxed `$Num`. `==` on `Number`
is `eqNumberImpl` (`f64.eq`), and `Data.Int.toNumber` is `f64.convert_i32_s`.

**`Int` Euclidean division** completes `Int`'s algebra (`Data.EuclideanRing`'s
`Int` instance — the top of the hierarchy; `Int` is *not* a `Field`, which needs a
`DivisionRing` multiplicative inverse). `div` / `mod` / `degree` reach the `intDiv`
/ `intMod` / `intDegree` foreigns through `euclideanRingInt`, and lower to three
shared runtime helpers — `$rt.intDiv` / `$rt.intMod` / `$rt.intDegree` — rather
than raw `i32.div_s` / `i32.rem_s`, because `Prelude` semantics differ from the
wasm instructions in two ways the helpers reproduce: a **non-negative remainder**
(`mod x y = ((x % |y|) + |y|) % |y|`, so `(-7) mod 2 = 1`, not `-1`) and a **zero
guard** (`x div 0 = x mod 0 = 0` instead of trapping). `intDiv` is then just
`(x - intMod x y) / y` — once the remainder is removed, the quotient divides
exactly, so no sign correction is needed.

**`Number` as a `Field`** completes `Number`'s algebra (`Field` = `EuclideanRing`
+ `DivisionRing`, the top of the hierarchy). This needed *no* new machine op:
`DivisionRing`'s `recip x = 1.0 / x` lowers through `Data.DivisionRing.div` — which
is `Data.EuclideanRing.div` partially applied to `euclideanRingNumber` (a CAF) — to
the existing `numDiv` (`f64.div`); and `Field` is law-only, its instance merely
bundling the `EuclideanRing` and `DivisionRing` superclass dictionaries. A
`Field`-constrained generic used at `Number` therefore links end-to-end through the
already-supported partial-application, CAF, and superclass-thunk paths.

**`Data.Bounded`** (`top` / `bottom`) for `Int` and `Char`. Unlike every class
above, these foreigns are *nullary values*, not functions — `topInt` / `bottomInt`
are the `i32` extremes (`2147483647` / `-2147483648`) and `topChar` / `bottomChar`
the code points `0xFFFF` / `0`, each boxed as `$Int`. A nullary foreign is
materialized directly (an arity-0 `RPrim`) instead of being eta-expanded to a
closure. `Bounded`'s `Ord` superclass drives comparisons; `Char` compares by code
point, identical to `Int`, so it reuses `OrdInt`. (`Number`'s `Bounded` is the two
`±Infinity` constants — implemented but not yet linkable until `Number`'s `Ord`
lands.) One subtlety this surfaced: the foreign-intrinsic table is keyed by *bare*
identifier, which collides with instance names like `topInt`; a defined top-level
binding (constructor / function / instance dictionary) therefore now **shadows** the
intrinsic table, and `foreignIntrinsic` is consulted only as a fallback (real
foreigns have no declaration body, so they are never shadowed).

**`Data.Semigroup`** (`<>` / `append`) for `String` and `Array`. `String` `<>`
(`concatString`) reuses the existing `$rt.strConcat` runtime helper. `Array` `<>`
(`concatArray`) uses a new `$rt.arrayConcat`: allocate a `$Vals` of the combined
length (`array.new` with a `ref.null eqref` initializer) and `array.copy` both
halves in — the array *is* the value, so there is no wrapping struct. (The other
`Semigroup` instances — records, functions, `Unit`, the `Monoid` newtypes — are not
exercised yet.)

**`Data.Monoid`** (`mempty`) and the `Additive` / `Multiplicative` newtype monoids.
`Data.Monoid` has no foreigns and needs no new machine op: `mempty` is a nullary
class method projected from the `Monoid` dictionary — `""` for `String`, `[]` for
`Array`, `Additive zero` / `Multiplicative one` for the Semiring-backed newtypes.
The newtype wrappers erase, so `Additive a <> Additive b` reduces straight through
the existing `Semigroup` / `Semiring` paths. Reaching this surfaced one new lowering
capability: a binary operator that destructures *both* operands
(`\(Additive a) (Additive b) -> …`) compiles to a **multi-scrutinee `case`**, which
is now desugared into right-nested single-scrutinee `case`s (one per column),
reusing the per-column lowering. (Multi-*alternative* multi-scrutinee matches still
need real column-wise pattern compilation and remain unsupported.)

**`Data.Show`** for every primitive type — `Int`, `Boolean`, `Char`, `String`,
`Array`, and `Number`. The rendering work lives in `runtime.wat` (ADR 0010):

- `Int` (`showIntImpl`) → `$rt.showInt`: write the base-10 digits into an 11-byte
  scratch from the right (extract with `rem_s` / `div_s`, `abs` of each remainder, so
  `INT_MIN` renders without ever negating the whole value), then copy the used suffix.
- `Boolean` is a pure `case` in `Data.Show` (no foreign): `"true"` / `"false"`.
- `Char` (`showCharImpl`) → `$rt.showChar`: quote with `'`, escaping control chars
  (named `\n` … or `\DDD`), `'` and `\`, and UTF-8-encoding any other code point.
- `String` (`showStringImpl`) → `$rt.showString`: quote with `"`, escaping `"`, `\`,
  named control chars, and other controls as `\DDD` (with the `\&` separator when a
  digit follows). It works byte-by-byte on the UTF-8 bytes — every escaped byte is
  `< 0x80`, so multi-byte sequences pass through untouched.
- `Array` (`showArrayImpl`) → `$rt.showArray`: `[` + each element shown by the
  element-show **closure** (`f`, called per element via `call_ref` from the runtime)
  joined with `,` + `]`. This is the first place the runtime *invokes* a generated
  closure across the module boundary — it relies on the same structural GC-type
  identity (now also for `$Clo` / `$Code`) that the import boundary uses.

- `Number` (`showNumberImpl`) → `$rt.showNumber`: the shortest decimal that
  round-trips to the same `f64`, matching JS `Number.toString()` exactly. It uses
  **Dragon4** (Steele–White / Burger–Dybvig) — a fixed-capacity big-integer (64
  `i32` limbs, base 2³², stored in the same `(array (mut i32))` as `$Bytes`) drives an
  exact scaled-value digit loop, so **no power-of-ten tables** are needed (the reason
  Ryū is impractical to hand-write in WAT). The digits + decimal-point position then
  go through the ECMAScript `Number::toString` formatting rules (fixed vs
  exponential, the `.0` suffix on integers, `Infinity`/`NaN`). Because the WAT can't
  be eyeballed for correctness, `compiler/test/showNumber.mjs` is an oracle test that
  drives the runtime from JS and compares against `String(n)` over **>1M random
  `f64` bit patterns** plus hand-picked edge cases (subnormals, `MAX_VALUE`,
  `5e-324`, powers of ten, `±0`, …) — currently bit-exact on every value.

**Extended `Eq` / `Ord`.** Beyond `Int` (and `Char`, which shares its
representation), equality and ordering now cover **`Boolean`** (`eqBooleanImpl` →
compare the `i31` bits; `ordBooleanImpl`), **`Number`** (`ordNumberImpl` via `f64.lt`
/ `f64.eq` — `Number`'s `Eq` was already wired), and **`String`** ordering
(`ordStringImpl` via a new `$rt.strCmp` lexicographic byte comparison). The three
`unsafeCompareImpl`-shaped foreigns (`ord{Int,Bool,Number,String}Impl`, the
`lt eq gt x y` form) share one `ordSelect` lowering, differing only in how the
operands are unboxed/compared. `String` order is by UTF-8 byte (= code-point order),
which differs from JS's UTF-16 order only for astral-vs-`U+E000..U+FFFF` mixes (a
documented consequence of the UTF-8 representation, ADR 0001). A `derive instance Eq`
on a **single-constructor** type works (it lowers to the single-alternative
two-scrutinee `case` of `nestColumns`, comparing each field with `&&`).

**`Eq` / `Ord` on `Array`** are the higher-order `eqArrayImpl` / `ordArrayImpl`:
they take the element eq/compare **closure** plus the two arrays, and the runtime
(`$rt.arrayEq` / `$rt.arrayOrd`) applies that closure per element via a curried
two-step `call_ref` (`$callClo2` — the first place the runtime makes a *curried
multi-argument* call into generated code). `arrayEq` does the length check then the
element-wise `&&`; `arrayOrd` returns the first non-zero element delta, else the
length comparison, which the caller maps back to an `Ordering` (`compare 0 …`).

*Derived* `Eq`/`Ord` on **multi-constructor** types (which need column-wise
decision-tree pattern compilation) are not wired up yet; nor are
`Data.Int.round`/`floor`/`…`.

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

Not yet supported: the `Record.*` library's **dynamic-`String`-key** operations
(`get`/`set`/`insert`/`delete` — they need a runtime string→label-id mapping, since
labels are interned to `i32` ids at compile time), and **polymorphic update** of an
open row (`copy` absent — the unknown extra fields need a runtime copy). Both are
deferred to the `Prelude` / `Record`-module stage.

## Host interface

Every exported function gets a thin `…$export` wrapper with the host-facing
`i32` signature (visible in the first example): it boxes the `i32` arguments,
calls the internal `eqref` function, and unboxes the `i32` result. Today the
host boundary is `Int`-typed; a binding whose value is not an `Int` (an instance
dictionary, say) still gets a wrapper, but it traps if actually called as `i32`.
