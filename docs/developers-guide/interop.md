# JS↔WASM interop: the marshalling internals

How PureScript values cross the boundary between the generated WebAssembly and JavaScript —
both when wasm calls a JavaScript `foreign import` and when JavaScript calls a wasm export.
This is the implementer's view (the decision is [ADR 0014](../design-decisions); the value
shapes being marshalled are in [Runtime representation](./runtime-representation.md)). For
the *authoring* side — how to write a foreign or call an export from JS — see the
user-facing FFI guide.

Where it lives in the code:

| Concern | Module |
| - | - |
| Classify a foreign's params/result into marshal kinds (from externs) | `compiler/.../Wasm/Externs.purs` (`foreignSigs`, `marshalKind`) |
| The marshal-kind type | `compiler/.../Wasm/Lower/IR.purs` (`MarshalKind`) |
| Resolve a foreign down the provider ladder | `purs-wasm/.../CLI/Build/Foreign.purs` (`resolveForeign`) |
| Emit the manifest + loader (`index.mjs`) | `purs-wasm/.../CLI/Build/Loader.purs` (`manifestJs`, `loaderSource`, `emitLoader`) |
| The conversion glue (shared with the e2e harness) | `runtime/marshal.js` (`makeMarshal`) |
| The read/build primitives the glue calls on the instance | `runtime/runtime.wat` |

- [The problem: wasm-GC values are opaque to JS](#the-problem)
- [The provider ladder](#the-provider-ladder)
- [Classifying a foreign: marshal kinds](#classifying-a-foreign-marshal-kinds)
- [The two directions](#the-two-directions)
- [What crosses, and how (per kind)](#what-crosses-and-how)
- [The mechanics: raw scalars, boxed everything-else, a JSON manifest](#the-mechanics)
- [The export path](#the-export-path)
- [The internal ABI of a merged foreign](#the-internal-abi-of-a-merged-foreign)
- [What is not supported yet, and why](#what-is-not-supported-yet)

## The problem

A PureScript value at run time is a Wasm-GC heap value — a `$Str` struct, a `$Vals` array,
a `$Rec`, an `i31` boolean (see [Runtime representation](./runtime-representation.md)).
JavaScript cannot introspect these: a `$Str` is not a JS `string`, a `$Vals` is not a JS
`Array`. So a value handed across the boundary must be **marshalled** — converted to the
other side's native shape and back. The exception is the raw scalars (`i32` / `f64`): a wasm
`i32`/`f64` already *is* a JS `number`, so it crosses with no work.

## The provider ladder

When the compiler meets a `foreign import` it resolves the implementation down a ladder
(ADR 0014; `resolveForeign`), stopping at the first that applies:

1. **Intrinsic table** — a built-in primitive (arithmetic, comparisons, `$rt.*` helpers).
   No host call.
2. **wasm / wat foreign** — a hand-written `foreign.wasm` / `foreign.wat` (the user's, or
   curated in the lib, ADR 0012 / 0031). It is **merged** (`wasm-merge`) into the program and
   speaks the [internal ABI](#the-internal-abi-of-a-merged-foreign) directly, so **no
   marshalling** is needed and the program stays self-contained.
3. **JS foreign** — a `foreign.js`. The compiler emits a wasm **host import**; the generated
   JS **loader** supplies it from `foreign.js`, wrapping it with the marshalling glue below.
   Such a program is no longer self-contained (wasm + a JS loader).
4. Otherwise — a trap / compile error.

Rungs 1–2 keep values at their internal representation end to end; only rung 3 crosses a
representation boundary and therefore needs marshalling. That is the whole reason the lib
ships wat foreigns rather than JS for the hot core: a merged foreign pays nothing at the
boundary. Note this is a *boundary*-cost win only — a merged foreign is still an opaque
reference to the MIR optimizer (no inlining or higher-order specialization through it), which
is why the lib writes its higher-order functions in PureScript over `Wasm.*`, not as wat.

## Classifying a foreign: marshal kinds

`marshalKind` walks a foreign's **externs type** and assigns each parameter and the result a
`MarshalKind`. Function arrows are peeled to give the parameter list and the trailing
result; `forall` quantifiers are transparent; constraints cannot occur (PureScript forbids
them on `foreign import`s). A foreign typed by a **nullary type synonym** (`type Point = {
… }`) is expanded first (`synonymTable`) so the alias is classified by its underlying type
rather than falling to `MOpaque`.

```haskell
data MarshalKind
  = MI32                         -- Int, Char
  | MF64                         -- Number
  | MBool                        -- Boolean
  | MStr                         -- String
  | MArray MarshalKind           -- Array a  (recurses on the element)
  | MRecord (Array (Tuple String MarshalKind))  -- record  (recurses per field)
  | MFunc MarshalKind MarshalKind               -- a -> b  (recurses on both sides)
  | MEffect MarshalKind          -- Effect a  (recurses on the yielded value)
  | MOpaque                      -- anything else
```

## The two directions

Marshalling is symmetric; only the direction of the conversions flips:

- **Import** — wasm calls a JS `foreign import`. The *arguments* go wasm→JS, the *result*
  comes JS→wasm.
- **Export** — JS calls a wasm export (a top-level value of the entry module). The
  *arguments* go JS→wasm, the *result* comes wasm→JS.

The same conversion routines (`eqrefToJs` / `eqrefFromJs`) and the same runtime helpers
serve both; the export side is the mirror image of the import side (`wrap` vs `wrapExport`
in `marshal.js`).

## What crosses, and how

Each kind has a conversion, expressed in terms of `runtime.wat` exports:

| kind | boundary value | how it converts |
| - | - | - |
| `MI32` | raw `i32` (a JS `number`) | nothing top-level; **boxed `$Int`** when nested (`boxInt`/`unboxInt`) |
| `MF64` | raw `f64` (a JS `number`) | nothing top-level; **boxed `$Num`** when nested (`boxNum`/`unboxNum`) |
| `MBool` | `i31ref` ⇄ JS `boolean` | `boxBool`/`unboxBool` (a `Boolean` is always boxed, so it crosses as an `eqref`) |
| `MStr` | `$Str` ⇄ JS `string` | read with `strLen`/`strByteAt`, build with `strNew`/`strSetByte` (UTF-8) |
| `MArray` | `$Vals` ⇄ JS `Array` | `arrayLen`/`arrayGet`, `arrayNew`/`arraySet`, recursing per element |
| `MRecord` | `$Rec` ⇄ JS `{}` | field-by-field: read via `proj`, build from `recEmpty` via `recSet`, keyed by `internStr` of each field name; recurses per field |
| `MFunc` | `$Clo` → JS `function` | the closure is wrapped in a JS function that marshals its argument in, applies the closure via the trampoline `applyClo`, and marshals the result out |
| `MEffect` | the thunk is **run on the JS side** | the JS impl (`s => () => …`) is applied to its value args, the returned thunk is performed (`()`) by the glue, and only the inner result is marshalled back (ADR 0015) — wasm never holds the JS thunk, sidestepping closure direction 2 |
| `MOpaque` | passed through as an opaque `eqref` | — (but a **JS-originated** opaque cannot cross back into wasm — see below) |

## The mechanics

The rule that ties it together: **top-level scalars cross raw; everything else crosses as an
`eqref` and is converted by generated glue.**

- A top-level `Int`/`Number` parameter or result is a raw `i32`/`f64` — already a JS
  `number`, no conversion (`isRaw` is true for `"i"`/`"f"`).
- Everything else (`String`, `Boolean`, `Array`, `Record`, closure, and a *nested*
  `Number`/`Int` inside a container) is an `eqref`. The glue (`eqrefToJs` / `eqrefFromJs` in
  `marshal.js`) converts it recursively, driven by a **manifest** — a JSON description of
  each foreign's parameter/result kinds:

  | `MarshalKind` | manifest |
  | - | - |
  | `MI32` / `MF64` / `MBool` / `MStr` / `MOpaque` | `"i"` / `"f"` / `"b"` / `"s"` / `"o"` |
  | `MArray k` | `{"a": <k>}` |
  | `MRecord [(l, k), …]` | `{"r": {"<l>": <k>, …}}` |
  | `MFunc p r` | `{"fn": [<p>, <r>]}` |
  | `MEffect k` | `{"eff": <k>}` |

  `manifestJs` bakes this into `index.mjs`; `eqrefToJs`/`eqrefFromJs` dispatch on it,
  calling the `runtime.wat` helpers on the live instance.

So a foreign `String -> String` has its `$Str` argument turned into a JS string and its
JS-string result turned back into a `$Str`; a foreign `Array (Record …) -> Int` has its
array-of-records argument walked element-by-element, field-by-field.

## The export path

The entry module's top-level values are exported. `rootExportSigs` keeps each root module's
signatures (keyed by bare name); the export wrapper exposes each parameter/result at its
representation (`i32`/`f64` raw, else `eqref`) and the loader wraps it with the mirror-image
glue (`wrapExport`: arguments JS→wasm, result wasm→JS). `exportNeedsLoader` decides per
export whether any param/result is non-raw — a plain `Int -> Int` export is just an `i32`
function and is callable on the raw instance with no loader at all.

Two reconciliations matter at this boundary, both [ADR 0024](../design-decisions):

- **Arity recovery for point-free exports.** A point-free top-level (`inc = add 1`, type
  `Int -> Int`) compiles to a *nullary* function returning a closure. The export wrapper
  recovers the full type arity — it calls the function and applies the remaining arguments to
  the returned closure — so `exports.inc(5) === 6` on both the loader and standalone paths.
- **The `C > T` CAF guard.** The loader eagerly evaluates a nullary export to present a CAF
  as a *value* (not a thunk), but only when the real wasm arity is also 0; a source-nullary
  binding that compiled to a function (a function newtype / collapsed monad) is exposed as a
  function instead.

An `Effect a` export is exposed as a **thunk** `() => a` (matching `Effect a ≃ () => a`,
ADR 0015), so importing the module does not run it.

## The internal ABI of a merged foreign

A wat/wasm foreign (rungs 1–2) is **not** marshalled — it is merged and must speak the
internal ABI: each function **exports the base name** the import expects and takes/returns
every value at its internal representation (a raw `i32`/`f64` for `Int`/`Number`, an `eqref`
otherwise):

```wat
;; foreign.wat for `Example.FFI` — provides `triple :: Int -> Int`
(module
  (func (export "triple") (param $n i32) (result i32)
    (i32.mul (local.get $n) (i32.const 3))))
```

Scalar foreigns are this simple. A wat foreign that builds or reads a **heap value** (`$Str`,
`$Vals`, `$Rec`, …) must declare those value types so they canonicalize with the program's:
that shared rec-group header is lib territory (it ships as `_header.wat`, prepended at
assembly time; ADR 0010 / 0031). This is why a merged foreign pays nothing at the boundary —
it already holds the program's own GC types.

## What is not supported yet

- **JS function → wasm (closure direction 2).** A foreign that hands a JS *function* back to
  wasm — only reachable via a function nested in a result, or a callback *argument* to an
  export — is deferred. It needs a JS-side function registry plus a host-import trampoline so
  wasm can hold and re-enter a JS callable; the glue raises a clear error meanwhile. (A
  foreign that merely *returns a function*, `a -> (b -> c)`, is not this case: it is the same
  type as the uncurried `a -> b -> c`.)
- **JS-originated opaque values round-tripping through wasm — the `eqref` vs `externref`
  question.** A foreign whose result is an opaque value *created on the JS side* (a `foreign
  import data` whose instances are JS objects — a handle returned by one foreign and later
  passed back to another) cannot be held by wasm and returned to a later foreign. `MOpaque`
  is carried as the internal GC `eqref`, but a JS object is an `externref`; returning it to a
  wasm `(result eqref)` import throws `TypeError: type incompatibility when transforming
  from/to JS` at run time. It is *not* caught at build time. The general fix (carry JS-origin
  opaques as `externref`, boxed in a wasm struct) is blocked on a representation ambiguity: a
  *polymorphically*-opaque value that is really a wasm-GC value (e.g. an `Int` read back out
  of a container declared opaque at the boundary) must stay an `eqref` so it can still be
  `ref.cast` to its concrete type, yet a genuinely JS-native opaque must be `externref` — and
  the marshalling boundary cannot tell them apart. So such libraries are better provided
  **wasm-natively** (a runtime intrinsic or a lib `foreign.wat`, ADR 0012 / 0017) than through
  the JS ladder. `Effect.Ref` was exactly this case — a pure mutable cell — and is **now
  provided natively** (a wasm `$Ref` struct, ADR 0017), so it no longer crosses the JS
  boundary at all.
- **`Object a`** (dynamic string keys) — its representation differs from the static-label
  `$Rec` and needs a separate decision.
- **`main :: Effect Unit` auto-run on load** — an `Effect`-typed export is exposed as a
  callable thunk; auto-running it on import is a possible future loader flag. (`Effect.Ref`,
  `forE`/`whileE`/`untilE`/`foreachE`, and `EffectFnN` are now provided wasm-natively —
  ADR 0017 / 0018 — not gaps; `ST` shares `Effect.Ref`'s representation and is the remaining
  follow-up.)
