# Supported Features

Which PureScript language features the backend supports, and how far. There is no WAT
here on purpose — the emitted code drifts as the compiler evolves and reading it isn't
the point. For the value *shapes* see [Runtime representation](./runtime-representation.md),
for how they are made fast [Optimizations](./optimizations.md), for crossing to
JavaScript [JS↔WASM interop](./interop.md), and for the build
[Compilation pipeline](./compilation-pipeline.md). Per-`Prelude`-module notes are in
[Prelude support](./supported-features/Prelude-support.md).

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
- [Foreign function interface](#foreign-function-interface)

## Top-level functions

Supported. Arithmetic and comparison go through `Prelude`'s type classes
(`Semiring`/`Ring`/`Ord`/…) and lower to machine intrinsics (`i32.add`, …); a saturated
call to a known top-level function is a direct call.

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
chain of one-argument closures (a PAP) — and **over-application** (supplying more
arguments than the arity) are supported. Multi-argument application of an *unknown*
function value is a chain of single-argument `call_ref`s.

## Recursive let-bindings

Self- and mutually-recursive local (`let` / `where`) functions are supported. A
self-recursive helper is lambda-lifted to a top-level supercombinator (which is also
what lets it tail-call); a mutually-recursive group is allocated and then **knot-tied**
(its environment slots back-patched to point at the siblings). Top-level (mutual)
recursion needs nothing special — each call is a direct call.

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
(`Eq` / `Ord` / `Generic`) works. **Not yet**: cyclic instance groups such as `Effect`'s
`Functor`/`Applicative`/`Monad` (→ [ADR 0015](./design-decisions)).

## Records

Construction, field access, **monomorphic update** (`r { x = v }`), and **pattern
destructuring** (`\{ x } -> …`) are supported, as are `Record.Unsafe`'s
dynamic-`String`-key operations (`unsafeGet` / `unsafeSet` / `unsafeHas` /
`unsafeDelete`), bridged by an emitted `internStr` resolver (label string → interned
id). Records share the label-map representation with dictionaries (→
[runtime-representation § Record](./runtime-representation.md#record)). **Deferred**:
polymorphic update of an open row (the unknown extra fields need a runtime copy).

## Foreign function interface

A `foreign import` beyond the built-in intrinsics is supported via a provider ladder:
a hand-written `foreign.wat` / `foreign.wasm` (merged, self-contained, no marshalling)
or a `foreign.js` (a host import marshalled by a generated loader). How to write each,
which to choose, and how values cross the boundary are documented in
[JS↔WASM interop](./interop.md).
