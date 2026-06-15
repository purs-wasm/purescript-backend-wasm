# Supported Features

Which PureScript language features the backend supports, and how far. There is no WAT
here on purpose — the emitted code drifts as the compiler evolves and reading it isn't
the point. For the value *shapes* see [Runtime representation](./runtime-representation.md),
for how they are made fast [Optimizations](./optimizations.md), for crossing to
JavaScript [JS↔WASM interop](./interop.md), and for the build
[Compilation pipeline](./compilation-pipeline.md).

- [Top-level functions](#top-level-functions)
- [Algebraic data types and pattern matching](#algebraic-data-types-and-pattern-matching)
- [Scalar literals and literal patterns](#scalar-literals-and-literal-patterns)
- [Strings](#strings)
- [Arrays](#arrays)
- [Closures and higher-order functions](#closures-and-higher-order-functions)
- [Function application, partial and over](#function-application-partial-and-over)
- [Recursive let-bindings](#recursive-let-bindings)
- [Tail-call elimination](#tail-call-elimination)
- [Typeclass dictionaries](#typeclass-dictionaries)
- [Records](#records)
- [The Effect monad](#the-effect-monad)
- [Foreign function interface](#foreign-function-interface)

## Top-level functions

Supported. Arithmetic and comparison go through `Prelude`'s type classes
(`Semiring`/`Ring`/`Ord`/…) and lower to machine intrinsics (`i32.add`, …); a saturated
call to a known top-level function is a direct call. `Int` division/modulo follow
`Data.EuclideanRing`: a **non-negative remainder** (`(-7) mod 2` is `1`) and a **zero
guard** (`x div 0` is `0`, no trap), unlike the raw, truncating, `/0`-trapping
`i32.div_s`/`rem_s`.

## Algebraic data types and pattern matching

ADTs (including recursive ones) are supported. Pattern matching compiles to a decision
tree and covers **multiple scrutinees** (`case x, y of …`), **nested** constructor /
literal / **array** (`[]`, `[a, b]`) patterns, **newtype erasure**, and **guards** (a
guarded alternative whose guards all fail falls through to later alternatives). An
exhaustive match's fall-through traps. Representation →
[runtime-representation § ADTs](./runtime-representation.md#algebraic-data-types).

## Scalar literals and literal patterns

`Int` / `Char` / `Number` / `Boolean` literals, and **literal patterns** (including the
`case` an `if` desugars to). A literal match is a decision tree of **value-equality
tests** (not an ADT-tag read); the catch-all arm is the `else`, and an exhausted match
with no catch-all traps. Representations →
[runtime-representation § Scalars](./runtime-representation.md#scalars).

## Strings

`String` literals and the foreign string operations (concatenation, length, equality).
A string is its **UTF-8 bytes**, so `length` counts *bytes*, not UTF-16 code units — a
deliberate divergence from `Data.String.CodeUnits`. Representation →
[runtime-representation § String](./runtime-representation.md#string).

## Arrays

Array literals, length, and indexing; arrays nest (`Array (Array a)`). Representation →
[runtime-representation § Array](./runtime-representation.md#array).

## Closures and higher-order functions

Full closures and higher-order functions. A lambda is lambda-lifted to a top-level code
function, capturing its free variables in an environment, and applied through an
arity-1 eval/apply ABI; a higher-order function called with a *known* function argument
is specialized so the closure disappears (see [Optimizations](./optimizations.md)).
Representation →
[runtime-representation § Closures](./runtime-representation.md#closures).

## Function application, partial and over

Both **partial application** — a known function under-applied is eta-expanded into a
chain of one-argument closures — and **over-application** (supplying more
arguments than the arity) are supported. Multi-argument application of an *unknown*
function value is a chain of single-argument `call_ref`s.

## Recursive let-bindings

Self- and mutually-recursive local (`let` / `where`) functions are supported. A
self-recursive helper is lambda-lifted to a top-level supercombinator (which is also
what lets it tail-call); a mutually-recursive group is allocated and then **knot-tied**
(its environment slots back-patched to point at the siblings). Top-level (mutual)
recursion needs nothing special — each call is a direct call.

A **point-free** recursive function — defined without an explicit lambda, e.g.
`purescript-run`'s `loop = resume f pure` — is **eta-expanded** to `\x -> loop' x` so it lowers
as a function (sound for a binding of positive residual arity). This is what lets `Free` / `Run`
code compile, though such interpreters are currently slow on wasm and the eta-expansion gives up
some closure sharing — see [optimizations § Known gaps](./optimizations.md#known-gaps). A genuinely
recursive **value** binding (a non-function that references itself, e.g. a self-referential
`Tuple`) is supported only at the **top level**, as a cyclic value CAF that globalization keeps as
a recomputed getter (ADR 0006); the same shape inside a local `let` is not yet supported.

## Tail-call elimination

A direct call in **tail position** runs in **constant stack** (emitted as
`return_call`), so top-level self/mutual tail recursion and lambda-lifted loop helpers
do not overflow (e.g. a million-iteration loop returns instead of overflowing). **Not**
covered: a tail call to an *unknown* closure value (a function argument), which would
need `return_call_ref`. Mechanism →
[optimizations § Tail-call elimination](./optimizations.md#tail-call-elimination).

## Typeclass dictionaries

Type-class resolution is supported. Where the instance is **statically known** (the
common case) the dictionary is **eliminated** — the method becomes a direct call to its
implementation (see [Optimizations](./optimizations.md)). A genuinely **polymorphic**,
dictionary-passing call instead carries a runtime dictionary — a label-map record (→
[runtime-representation § Record](./runtime-representation.md#record)) searched per
method, including superclass access (arbitrarily deep hierarchies work). Deriving
(`Eq` / `Ord` / `Generic`) works. **Cyclic instance groups** such as `Effect`'s
`Functor`/`Applicative`/`Monad` are supported too (→ [The Effect monad](#the-effect-monad)).

## Records

Construction, field access, **monomorphic update** (`r { x = v }`), and **pattern
destructuring** (`\{ x } -> …`, including nested field patterns like `\{ x: Just y } -> …` —
these compile via the general Maranget decision tree; only the allocation-free fast path is
restricted to var/wildcard field binders) are supported, as are
`Record.Unsafe`'s
dynamic-`String`-key operations (`unsafeGet` / `unsafeSet` / `unsafeHas` /
`unsafeDelete`), bridged by an emitted `internStr` resolver (label string → interned
id). Records share the label-map representation with dictionaries (→
[runtime-representation § Record](./runtime-representation.md#record)). **Polymorphic
update** of an open row is supported too — the unknown extra fields are preserved by a
runtime copy-and-set (ADR 0023).

**Record metaprogramming** works: `RowToList` field iteration with
`IsSymbol`/`reflectSymbol`, and `Record.insert` / `Record.Builder` / `Record.merge` and the
`record-studio`-style helpers. Adding a field whose name is **not** a syntactic record label
anywhere — so it has no compile-time id — is supported via runtime label interning
(`$rt.internDynamic`, the [ADR 0001](../design-decisions/0001-wasm-gc-substrate-and-value-representation.md)
addendum); `Test.E2E.Cli.RecordMeta` covers it. Library helpers that route through a higher-order
JS foreign whose callbacks carry non-scalar values (e.g. `record-studio`'s `keys`/`shrink` via
`unfoldrArrayImpl`) are **not** yet usable — see
[Performance and Limitations § higher-order foreigns whose callbacks carry non-scalar values](../getting-started/performance-and-limitations.md#higher-order-foreigns-whose-callbacks-carry-non-scalar-values).

## The Effect monad

`Effect` is supported, including its mutually-recursive `Functor`/`Apply`/`Applicative`/
`Bind`/`Monad` instances and `do`-notation. `Effect` is opaque, so it is made transparent
by **impurification** into the function encoding `Effect a ≃ Unit -> a` (ADR 0015), after
which the general optimizer collapses a pure `Effect` computation to the same allocation-
free, constant-stack code a transparent `newtype` monad gets — a deep `Effect` loop runs
in constant stack where a JavaScript backend overflows (→
[Optimizations § Effect](./optimizations.md#worked-example-the-effect-monad)). A
**purity analysis** keeps *genuinely effectful* runs from being dropped, reordered, or
duplicated, so a `foreign import log :: String -> Effect Unit` runs exactly when and as
often as written (→ [JS↔WASM interop](./interop.md#an-effectful-foreign)). `unsafePerformEffect`
is supported, as are **native mutable references** (`Effect.Ref`, ADR 0017) and the
**`effect` control-flow primitives** (`forE` / `foreachE` / `whileE` / `untilE`) and
**`EffectFnN`** (ADR 0018) — all provided wasm-natively. An `Effect`-typed export
(`main :: Effect Unit`) is exposed to JS as a callable thunk `() => a` — `exports.main()`
runs it (it does not run merely on import). **Not yet**: auto-running `main` on load
without an explicit call, and `ST` (which will share `Effect.Ref`'s representation).

## Foreign function interface

A `foreign import` beyond the built-in intrinsics is supported via a provider ladder:
a hand-written `foreign.wat` / `foreign.wasm` (merged, self-contained, no marshalling)
or a `foreign.js` (a host import marshalled by a generated loader). This includes
**effectful foreigns** (`a -> Effect b`, the `console.log` shape): the loader runs the
foreign's thunk on the JS side. How to write each, which to choose, and how values cross
the boundary are documented in [JS↔WASM interop](./interop.md).
