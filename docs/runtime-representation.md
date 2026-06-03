# Runtime representation of PureScript values

How each PureScript value is laid out in WebAssembly at run time. This is a
reference for the **value substrate**; for the WAT a given feature lowers to see
[Supported Features](./supported-features.md), for the design rationale see the
[ADRs](./design-decisions), and for how values cross to JavaScript see
[JS↔WASM interop](./interop.md).

- [The two-level picture: boxed baseline, unboxed where it pays](#the-two-level-picture)
- [Summary table](#summary-table)
- [Scalars: Int, Char, Number, Boolean](#scalars)
- [String](#string)
- [Array](#array)
- [Record](#record)
- [Algebraic data types](#algebraic-data-types)
- [Closures](#closures)
- [Unit and erased values](#unit-and-erased-values)
- [Where the types are defined](#where-the-types-are-defined)

## The two-level picture

The backend targets **Wasm GC** (ADR 0001): values are heap structs/arrays (or
`i31`/scalars) managed by the host garbage collector, not linear memory. The base
calling convention is **uniform `eqref`** (ADR 0004) — *any* value can be held as an
`eqref`, which is what makes parametric polymorphism and generic containers work.

On top of that, **representation analysis** (ADR 0013) unboxes a value where it can
prove the `eqref` is unnecessary. So most types have two forms:

- a **boxed form** — a GC value usable as an `eqref` (used in polymorphic positions,
  container elements, anywhere a uniform representation is needed);
- sometimes an **unboxed form** — a raw `i32` / `f64` / `i31ref` (used in
  monomorphic positions where the boxing would be pure overhead).

Each value slot (a function parameter, a `let` temporary, a constructor field) is
assigned one of four representations: `I32`, `F64`, `Boxed` (the `eqref`), or
`CloRef` (a closure's `(ref $Clo)`). Boxing/unboxing happens only at the boundaries
between slots of different representation.

## Summary table

| PureScript | boxed form (`eqref`) | unboxed form | notes |
| - | - | - | - |
| `Int`, `Char` | `$Int = (struct i32)` | raw `i32` | `Char` is a code point |
| `Number` | `$Num = (struct f64)` | raw `f64` | |
| `Boolean` | `i31ref` (`true` = 1, `false` = 0) | — (`i31` is already unboxed) | a heap struct would be wasteful; `i31`'s 31 bits are plenty for a tag |
| `String` | `$Str = (struct (ref $Bytes))` | — | `$Bytes = (array (mut i32))`, UTF-8 bytes, one per `i32` lane |
| `Array a` | `$Vals = (array (mut eqref))` | — | elements are boxed |
| `Record { … }` | `$Rec = (struct (ref $LabelIds) (ref $Vals))` | — | parallel interned-label-id / value arrays |
| `data` (ADT) | `$Data` base + `$Data_<sig>` subtypes | enum-like (all-nullary) → `i31` tag | concrete scalar fields unboxed in the struct |
| `a -> b` (closure) | `$Clo = (struct funcref (ref $Vals))` | — | code pointer + captured environment |
| `Unit` | erased | — | a shared no-op value |

## Scalars

- **`Int` / `Char`.** Boxed as `$Int = (struct i32)`. A PureScript `Int` is a full
  32-bit value, so the box holds an `i32` (not an `i31` — packing it into 31 bits
  would silently overflow at 2³⁰; ADR 0013). Unboxed, an `Int` flows as a raw `i32`,
  which is the common case after representation analysis (arithmetic, loop counters,
  ADT scalar fields). `Char` shares the representation (its code point as an `i32`).
- **`Number`.** Boxed as `$Num = (struct f64)`; unboxed as a raw `f64`.
- **`Boolean`.** An unboxed **`i31ref`** (`true` = 1, `false` = 0). Unlike `Int` it is
  never given a heap struct — `i31` is allocation-free and a bit is all it needs. It
  only widens to an `i32` at the point it is used as a condition.

## String

`$Str = (struct (ref $Bytes))` wrapping `$Bytes = (array (mut i32))`: the UTF-8 bytes
of the string, **one byte per `i32` array lane** (not bit-packed). String literals are
built by `array.new_fixed` over the UTF-8 bytes; the runtime exposes
`strLen`/`strByteAt` to read and `strNew`/`strSetByte` to build (used by the interop
glue). See [Supported Features § Strings](./supported-features.md#strings).

## Array

`$Vals = (array (mut eqref))` — a GC array of boxed elements. Because the element type
is the uniform `eqref`, an `Array Int` stores each element as a boxed `$Int`; this is
the same shape JavaScript uses (a boxed number in a cell). See
[Supported Features § Arrays](./supported-features.md#arrays).

## Record

A record is `$Rec = (struct (ref $LabelIds) (ref $Vals))` — **two parallel arrays**:

- `$LabelIds = (array (mut i32))` — the field labels as **interned integer ids**, kept
  sorted ascending;
- `$Vals` — the field values (boxed `eqref`), in the same order.

Labels are interned **per program**: every record label in the linked program is
assigned a dense `i32` id, so a field access is an integer comparison, not a string
compare. A projection (`r.l`) is a linear search of `$LabelIds` for the label's id,
returning the parallel `$Vals` element (`$rt.proj`; records are never empty, ADR 0007).
`Record.Unsafe`'s string-keyed access reaches the ids through an exported `internStr`
(string → id) resolver. See
[Supported Features § Records](./supported-features.md#records).

## Algebraic data types

An ADT is an **open base struct** plus one **subtype per constructor shape** (front-B,
ADR 0013):

- `$Data = (struct i32)` — the base, holding just the **constructor tag** (field 0);
- `$Data_<sig> = (sub $Data (struct i32 <field…>))` — one subtype per distinct
  field-representation signature, prepending the tag to the fields.

Field representations come from the externs (`externs.cbor`): a **concrete scalar
field** (`Int`/`Number`/`Char`) is stored **unboxed** in the struct (an `i32`/`f64`
field), while a polymorphic or non-scalar field stays a boxed `eqref`. So `Cons Int
IntList` is `(sub $Data (struct i32 i32 eqref))` (tag, the unboxed `Int`, the boxed
tail), allocating once. Reading a constructor's tag is a `struct.get` of field 0 on the
base; matching casts to the subtype.

**Enum-like ADTs** (every constructor nullary, e.g. `Ordering`) need no fields, so they
are represented as bare **`i31` tags** rather than structs; nullary constructors are
shared as module globals. See
[Supported Features § ADTs](./supported-features.md#algebraic-data-types-and-pattern-matching).

## Closures

`$Clo = (struct funcref (ref $Vals))`:

- the **code** as a generic `funcref` (kept generic, not `(ref $Code)`, so a lifted
  function's structurally-equal type matches for `call_ref`);
- the **captured environment** as a `$Vals` array of the free variables.

Closures use an **arity-1 ABI**: the code signature is `$Code = (func (param (ref
$Clo) eqref) (result eqref))` — it takes the closure (to reach its environment) and one
argument. A multi-argument function is a chain of these (apply one argument, get back a
closure, apply the next); a saturated call to a *known* top-level function skips the
closure entirely (a direct `call`). Building a closure is `array.new_fixed` (env) +
`ref.func` (code) + `struct.new $Clo`; applying one is read the `funcref` → `ref.cast`
to `(ref $Code)` → `call_ref`. See
[Supported Features § Closures](./supported-features.md#closures-and-higher-order-functions).

## Unit and erased values

`Unit` carries no information, so it is **erased** — `Data.Unit.unit` is a shared no-op
value, not a heap allocation. (`unsafeCoerce` is likewise the identity.)

## Where the types are defined

The value types are **hand-written** in `runtime/runtime.wat` (ADR 0010 — the shared
runtime is a separate wasm module the generated code imports / is merged with) and must
match the code generator's `Codegen.RuntimeTypes.buildRuntimeTypes` **structurally**.
They are declared as **individual (singleton) recursion groups**: the value rec-group
is acyclic, so Binaryen emits each generated type as its own singleton group, and a
singleton type is a *different* canonical type from one inside a multi-type `(rec …)`.
Declaring them individually on both sides makes a `$Str`/`$Vals`/… built by a generated
module survive a `ref.cast` across the import boundary. The per-constructor ADT
subtypes (`$Data_<sig>`) are program-specific and built by the code generator, not in
`runtime.wat`.
