# 0001. Wasm GC substrate and value representation

- Status: Accepted
- Date: 2026-05-31

## Context

PureScript is a pure functional language: programs allocate large numbers of
short-lived immutable values (ADTs, records, closures). The standard JS
backend leans entirely on the host's objects and garbage collector. A
WebAssembly backend must choose how heap values are represented and reclaimed.

Two substrates are available through Binaryen:

- **Wasm GC** — the `gc` proposal: `struct`, `array`, typed `ref`, and
  `i31ref`, reclaimed by the host VM's garbage collector.
- **Linear memory** — a flat `i32`-addressed byte heap that the produced
  module manages itself.

CoreFn is (mostly) type-erased, so the code generator generally does not know
the concrete row of a record, the field types of a data constructor, or the
class a dictionary belongs to. The representation must therefore work without
that type information.

## Decision

**Target Wasm GC.** Rely on the host VM's garbage collector; do not implement
an allocator or collector in the produced module.

Use **`eqref` as the universal boxed value type** — it is the common
supertype of both `i31ref` and all `struct`/`array` types, so any PureScript
value can be held uniformly where the type is unknown (container elements,
captured closure variables, ADT fields, record values). Keep `i32`/`f64`
**unboxed** only inside monomorphic arithmetic; box at polymorphic boundaries.

Target recursive type group (the concrete shapes the code generator builds
via Binaryen's TypeBuilder):

```wat
(rec
  (type $Bytes  (array i8))
  (type $Vals   (array (mut eqref)))               ;; ADT fields / Array elements
  (type $Int    (struct (field i32)))              ;; Number → f64, Char → i32 are the same shape
  (type $Num    (struct (field f64)))
  (type $Str    (struct (field (ref $Bytes))))     ;; UTF-8 (see Consequences)
  (type $ADT    (struct (field i32)                ;; constructor tag
                        (field (ref $Vals))))      ;; fields
  (type $Rec    (struct (field (ref $Labels))      ;; sorted labels
                        (field (ref $Vals))))      ;; parallel values
  (type $Labels (array (ref $Str)))
  (type $Code   (func (param (ref $Clo) eqref) (result eqref)))
  (type $Clo    (struct (field (ref $Code))))      ;; each lambda subtypes this, adding captured fields
)
```

Per-kind representation:

- **Int** `(struct i32)`, **Number** `(struct f64)`, **Char** `(struct i32)`
  (code point). `i31ref` cannot hold a 32-bit `Int`, so `Int` is a struct.
- **Boolean** and **Unit** → `i31ref` (`Unit` is a singleton).
- **String** → `(struct (ref (array i8)))`.
- **Array** → `(array (mut eqref))`.
- **ADT** → uniform `tag : i32` + `fields : (array eqref)`. A **newtype** is
  erased to its underlying value, driven by the CoreFn `IsNewtype` meta.
- **Record** → a **uniform label-map** (labels sorted; values parallel). This
  works without type information and directly backs Prelude's
  `unsafeGet/unsafeSet/unsafeHas/unsafeDelete`. **Type-class dictionaries are
  ordinary records in CoreFn and use this same representation.**
- **Closure** → closure conversion: a base `$Clo` struct holding a code
  reference, with each lambda a subtype that adds its captured fields; calls
  go through `call_ref`. PureScript curries, so each lambda is arity-1 at this
  level. Mutual recursion (`Rec`) is tied by allocating the closure structs
  first with mutable env fields left null, then back-patching them.

## Consequences

- No hand-written allocator/GC, and closure/ADT/record/array map naturally
  onto GC types — a large reduction in runtime engineering.
- **Requires a host that implements Wasm GC.** Node 22+/modern browsers
  qualify, which matches this repo's toolchain (see `flake.nix` `nodejs_24`).
  Older runtimes are unsupported by construction.
- Uniform `eqref` boxing means scalars are heap-allocated in polymorphic
  positions; an unboxing/representation optimization is left for later.
- String is **UTF-8**, which differs from `Data.String.CodeUnits`' UTF-16
  code-unit semantics. This divergence must be documented and revisited if/when
  code-unit-accurate string operations are required.
- The uniform label-map record gives O(n) field access; a nominal-struct /
  monomorphized representation is a future optimization (it needs type
  reconstruction or whole-program monomorphization, which we are not doing
  yet).

## Alternatives considered

- **Linear memory + self-hosted GC.** Runs on any wasm runtime, but requires
  writing an allocator and a real garbage collector (reference counting or
  semi-space), plus manual knot-tying for recursive closures. Rejected as
  disproportionate effort for the milestone.
- **`i31ref` for `Int`.** Rejected: 31 bits cannot represent a 32-bit `Int`.
- **Nominal per-type structs for records/ADTs from the start.** Faster, but
  needs type information CoreFn does not carry. Deferred to a later
  optimization pass.
