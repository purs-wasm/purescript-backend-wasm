# 0001. Wasm GC substrate and value representation

- Status: Accepted
- Date: 2026-05-31

> **Correction (2026-06-07):** The ADT value representation was later superseded by **[ADR 0013](0013-int-number-unboxing.md)**. ADTs are no longer the closed `$ADT = (struct i32 (ref $Vals))` of this record, but an **open base `$Data = (struct i32)` plus per-signature subtypes `$Data_<sig>` (scalar fields unboxed)**. The dead `$ADT` type has since been removed from `Codegen/RuntimeTypes` (it was unused; each value type is emitted as an independent singleton rec group, so dropping it is behaviour-neutral). The rest of this record (the wasm-GC substrate, eqref, `$Int`/`$Num`/`$Str`/`$Clo`, …) still holds.
>
> **Correction (2026-06-13):** Several concrete shapes in the Decision's WAT block and prose below drifted from the shipped runtime (`Codegen/RuntimeTypes.purs`, `runtime/runtime.wat`). The substrate decision (Wasm GC, uniform `eqref`, boxed scalars, label-map records, closure conversion) stands; the corrected representations are:
> - **`$Bytes` / `$Str`**: `$Bytes` is `(array (mut i32))` — one UTF-8 byte per `i32` lane, *not* a packed `(array i8)`; `$Str = (struct (ref $Bytes))`.
> - **`$Rec` / labels**: record labels are **interned dense `i32` ids**, not sorted `$Str` references. There is no `$Labels`/`(array (ref $Str))`; instead `$LabelIds = (array (mut i32))` and `$Rec = (struct (ref $LabelIds) (ref $Vals))` (parallel label-id / value arrays).
> - **`$Clo` / `$Code`**: closures are **not** per-lambda subtypes. `$Clo = (struct funcref (ref $Vals))` — a single non-subtyped struct holding the code as a generic `funcref` plus a captured-env `$Vals` array (a free variable is read positionally: `EnvField i`). The code field is deliberately `funcref` (its lifted body structurally matches `$Code`), and `$Code` is built in a **separate** type group, not `$Clo`'s. Mutual recursion is knot-tied by back-patching the **env array** (`array.set` into the `(mut eqref)` `$Vals`), not by mutable struct fields on subtypes.
> - **Type-group structure**: the value types are each emitted as an **independent singleton rec group** (not one multi-member `(rec …)`); `$Ref = (struct (mut eqref))` was added later for `Effect.Ref`/`STRef` (ADR 0017).
> - **String semantics**: the UTF-8 vs `Data.String.CodeUnits` note in Consequences was refined by **[ADR 0030](0030-data-string-over-utf8.md)** — `Data.String.CodeUnits` is **code-point**-indexed over UTF-8 (an astral char counts as 1), not UTF-16 code-unit-indexed; byte-level access lives in `Wasm.String`.
>
> **Update (2026-06-13) — runtime label interning (for record metaprogramming):** the uniform
> label-map gives each label a program-wide **interned `i32` id**. Those ids were a *closed,
> compile-time* set: `collectLabels` enumerates every **syntactic** record label (a `{l: …}` literal,
> a `.l` accessor, an `r {l = …}` update, a `{l: pat}` binder) and assigns dense ids `0..N-1`, and the
> string→id resolver `$internStr` (used by the string-keyed `Record.Unsafe` ops) ended in
> `unreachable` for anything outside that set. That broke **record metaprogramming that introduces a
> field whose name is not a syntactic label** (`Record.insert` / `Record.Builder` / `unsafeSet` over a
> computed or `Symbol`-only name): the new label had no id, so `$internStr` trapped. The id space is
> now **hybrid**: static labels keep their compile-time `0..N-1` ids (the dictionary/record fast path
> is unchanged), and `$internStr` falls back to a **runtime intern table** (`$rt.internDynamic`,
> `runtime.wat`) that find-or-appends an unknown name and returns `N + index`. Dynamic ids therefore
> never collide with static ones, and `recSet`'s sorted insert keeps each record's `$LabelIds` ordered
> for any id, so a dynamically-named field is read/written like any other. Reads, iteration, and
> in-place updates were always fine; this closes field *addition*. (Regression: `Test.E2E.Cli.RecordMeta`.)
>
> **Update (2026-06-18) — superseded by deterministic hashing (ADR 0037 ④):** the hybrid scheme
> above (dense `0..N-1` static ids + the `$rt.internDynamic` runtime table for dynamic names) is
> **gone**. A label's id is now a **31-bit FNV-1a hash of its UTF-8 bytes** (`Lower.LabelHash`,
> matching `runtime.wat`'s `$rt.internStr`), so it is a pure function of the name — no whole-program
> numbering pass, which is what lets modules be compiled separately (ADR 0037 barrier ④). There is no
> `internDynamic` and no static/dynamic id-space split: a dynamically-introduced field name hashes to
> the same id a syntactic label would. The lowering checks the program's whole label set for a hash
> collision and fails the build rather than emit a corrupt record (astronomically unlikely at realistic
> label counts). `recSet`'s sorted insert is unaffected (the hash is masked non-negative).

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
- ~~**ADT** → uniform `tag : i32` + `fields : (array eqref)`~~. A **newtype** is
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
