# `Prelude` Support

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

**`Functor` / `Apply` / `Bind` on `Array`** — `map` / `<$>` (`arrayMap`), `<*>`
(`arrayApply`), `>>=` (`arrayBind`). Each applies the element closure per element
from the runtime (`$callClo1`, a single `call_ref`) and builds a new `$Vals`:
`arrayMap` is 1:1; `arrayApply` is the `fs`-major cross product (length `l*k`);
`arrayBind` is a two-pass `flatMap` (apply `f` and sum sub-array lengths, then copy
them into one result). So e.g. `(+) <$> [1,2] <*> [10,20]` and `xs >>= f` run.

The **`Function` (`(->) r`, "Reader") instances** work too, and carry *no* foreigns:
`map = (<<<)`, `apply f g x = f x (g x)`, `pure = const`, `bind m f x = f (m x) x`,
plus `Semigroupoid`'s `<<<` / `>>>` and `Category`'s `identity`. They are pure
closure construction + application, so they lower with nothing beyond the existing
closure machinery — including **`do`-notation over functions**. With both the
`Array` and `Function` instances covered (and `Monad` being law-only), the
`Control.*` class modules — `Semigroupoid`, `Category`, `Functor`, `Apply`,
`Applicative`, `Bind`, `Monad` — and their Prelude instances are supported.

`do`-notation needs no special handling: PureScript desugars it *before* CoreFn into
nested `bind` / `pure` / `discard`, so the backend only ever sees those applications.
(`Effect` / `ST` `do`, which sequence side effects, are a separate item that does
need dedicated compiler support.)

**General pattern matching → decision trees.** A `case` over one *or many*
scrutinees with multiple constructor / literal / nested alternatives compiles to a
**decision tree** of `Switch` / `LitSwitch` nodes (`Lower.Match`, the classic
column-wise algorithm: pick a column, switch on its constructors with the fields
projected into each branch, recurse on the default matrix; newtype constructors are
erased onto the same occurrence). This unlocks:

- *Derived* `Eq` / `Ord` on **multi-constructor** types (`derive instance Eq Color`,
  `data Shape = Circle Int | Rect Int Int`) — the flat `case x, y of C1, C1 → …`
  purs generates.
- **`Generic`-based deriving** — `derive instance Generic` + `genericEq` works:
  `from` both values and compare their representations
  (`Sum`/`Product`/`Inl`/`Inr`/`Constructor`/`Argument`), which is exactly such a
  multi-scrutinee match over the rep.

Case **guards** (`| cond`) are still rejected, and `Data.Int.round`/`floor`/`…` are
not wired up.
