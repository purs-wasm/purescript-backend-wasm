# JS↔WASM interop: sending values to and from the wasm world

How PureScript values cross the boundary between the generated WebAssembly and
JavaScript — both when wasm calls a JavaScript `foreign import`, and when JavaScript
calls a wasm export. The design is [ADR 0014](./design-decisions); the value shapes
being marshalled are in [Runtime representation](./runtime-representation.md).

- [The problem: wasm-GC values are opaque to JS](#the-problem)
- [How a foreign is resolved: the provider ladder](#the-provider-ladder)
- [The two directions](#the-two-directions)
- [What crosses, and how (per type)](#what-crosses-and-how)
- [The mechanics: raw scalars, boxed everything-else, a JSON manifest](#the-mechanics)
- [Writing a foreign import](#writing-a-foreign-import)
- [Calling a wasm export from JS](#calling-a-wasm-export-from-js)
- [What is not supported yet](#what-is-not-supported-yet)

## The problem

A PureScript value at run time is a Wasm-GC heap value — a `$Str` struct, a `$Vals`
array, a `$Rec`, an `i31` boolean (see [Runtime representation](./runtime-representation.md)).
JavaScript cannot introspect these: a `$Str` is not a JS `string`, a `$Vals` is not a
JS `Array`. So a value handed across the boundary must be **marshalled** — converted
to the other side's native shape and back. The exception is the raw scalars (`i32` /
`f64`): a wasm `i32`/`f64` already *is* a JS `number`, so it crosses with no work.

## The provider ladder

When the compiler meets a `foreign import` it resolves the implementation down a
ladder (ADR 0014), stopping at the first that applies:

1. **Intrinsic table** — a built-in primitive (arithmetic, comparisons, `$rt.*`
   helpers). No host call.
2. **wasm / wat foreign** — a hand-written `foreign.wasm` / `foreign.wat` (the user's,
   or curated in `ulib`, ADR 0012). It is **merged** into the program and speaks the
   internal ABI directly, so **no marshalling** is needed and the program stays
   self-contained.
3. **JS foreign** — a `foreign.js`. The compiler emits a wasm **host import**; a
   generated JS **loader** supplies it from `foreign.js`, wrapping it with the
   **marshalling glue** below. Such a program is no longer self-contained (wasm + a JS
   loader).
4. Otherwise — a trap / compile error.

## The two directions

Marshalling is symmetric; only the direction of the conversions flips:

- **Import** — wasm calls a JS `foreign import`. The *arguments* go wasm→JS, the
  *result* comes JS→wasm.
- **Export** — JS calls a wasm export (a top-level value of the entry module). The
  *arguments* go JS→wasm, the *result* comes wasm→JS.

The same conversion routines (`eqrefToJs` / `eqrefFromJs`) and the same runtime helpers
serve both; the export side is the mirror image of the import side.

## What crosses, and how

Each parameter/result is classified into a **marshal kind** from its externs type, and
each kind has a conversion:

| PureScript | kind | top-level (boundary value) | how it converts |
| - | - | - | - |
| `Int`, `Char` | `MI32` | raw `i32` (a JS `number`) | nothing — crosses directly |
| `Number` | `MF64` | raw `f64` (a JS `number`) | nothing top-level; **boxed `$Num`** when nested (via `boxNum`/`unboxNum`) |
| `Boolean` | `MBool` | `i31ref` ⇄ JS `boolean` | `boxBool`/`unboxBool` (a `Boolean` is always boxed, so it crosses as an `eqref`) |
| `String` | `MStr` | `$Str` ⇄ JS `string` | read with `strLen`/`strByteAt`, build with `strNew`/`strSetByte` (UTF-8) |
| `Array a` | `MArray` | `$Vals` ⇄ JS `Array` | `arrayLen`/`arrayGet` / `arrayNew`/`arraySet`, recursing on each element's kind |
| `Record { … }` | `MRecord` | `$Rec` ⇄ JS `{}` | field-by-field: read via `proj`, build from `recEmpty` via `recSet`, keyed by `internStr` of the type's field names; recurses on each field's kind |
| `a -> b` | `MFunc` | `$Clo` → JS `function` | the closure is wrapped in a JS function that, when called, marshals its argument in, applies the closure via the runtime trampoline `applyClo`, and marshals the result out |
| `Effect a` | `MEffect` | the foreign's thunk is **run on the JS side** | the JS impl (`s => () => …`) is applied to its value args, then the returned thunk is performed (`()`) by the glue, and only the inner result `a` is marshalled back (ADR 0015) — wasm never holds the JS thunk, sidestepping closure direction 2 |
| anything else | `MOpaque` | passed through as an opaque `eqref` reference | — (but a **JS-originated** opaque value cannot cross back into wasm — see limitations) |

The runtime (`runtime/runtime.wat`) exposes the read/build primitives above as exports
so the JS glue can call them on the live instance.

## The mechanics

The rule that ties it together: **top-level scalars cross raw; everything else crosses
as an `eqref` and is converted by generated glue.**

- A top-level `Int`/`Number` parameter or result is a raw `i32`/`f64` — already a JS
  `number`, no conversion.
- Everything else (`String`, `Boolean`, `Array`, `Record`, closure, and a *nested*
  `Number`/`Int` inside a container) is an `eqref`. The generated **glue**
  (`eqrefToJs` / `eqrefFromJs`) converts it, recursively, driven by a **manifest**: a
  JSON description of each foreign's parameter/result kinds (`"i"`/`"f"`/`"b"`/`"s"`
  leaves, `{"a":…}` array, `{"r":{…}}` record, `{"fn":[…]}` function). The production
  loader bakes the manifest; the conversion calls the runtime helpers on the instance.

So a foreign `String -> String` has its `$Str` argument turned into a JS string and its
JS-string result turned back into a `$Str`; a foreign `Array (Record …) -> Int` has its
array-of-records argument walked element-by-element, field-by-field.

## Writing a foreign import

Declare the `foreign import`, then provide an implementation. The build resolves it
down the [provider ladder](#the-provider-ladder); you pick the rung by which file you
place next to the module in the build input (`<input>/<Module>/…`), checked in order:

| File | How it is used | Marshalling | Artifact |
| - | - | - | - |
| `foreign.wasm` | merged into the program | none — speaks the internal ABI | self-contained wasm |
| `foreign.wat` | assembled (`wasm-as`), then merged | none — internal ABI | self-contained wasm |
| `foreign.js` | a host import the generated loader satisfies | the glue, per the manifest | wasm + `index.mjs` loader |

Choose **wat/wasm** for a self-contained, platform-agnostic, or performance-critical
foreign (and for curated `ulib` modules, ADR 0012); choose **js** to reuse an existing
JavaScript implementation unchanged. If none is provided and the name is not a built-in
intrinsic, the call traps.

### A JS foreign

```purescript
module Example.FFI where

foreign import shout :: String -> String
```

```javascript
// foreign.js — the foreign sees plain JS values; the loader marshals $Str ↔ string
export const shout = (s) => s.toUpperCase();
```

The build emits a host import for `shout` and a generated **loader** (`index.mjs`) that
imports `foreign.js`, wraps `shout` with marshalling per the baked manifest, and
instantiates the module. The foreign sees a plain JS `string` and returns one; the glue
does the rest. A program with **no** JS foreigns emits no loader — it stays a single
self-contained `index.wasm`.

### An effectful foreign

A `foreign import` whose result is `Effect a` is a side-effecting host call (the
`console.log` shape). Write it as the usual curried PureScript FFI:

```purescript
module Example.Hello where

import Effect (Effect)

foreign import log :: String -> Effect Unit
```

```javascript
// foreign.js — the standard `s => () => …` shape: take the value arg, return a thunk
export const log = (s) => () => console.log(s);
```

When wasm performs `log "hi"`, the loader applies the value argument *and runs the
returned thunk on the JS side* (`log("hi")()`), marshalling only the inner result. So the
side effect happens at the boundary and wasm never has to hold or re-enter a JS function.
The optimizer recognises `log` as effectful (its result type is `Effect _`) and so will
not drop, reorder, or duplicate the call (see
[Effect impurification and purity](./optimizations.md#effect-impurification-and-purity)).

An `Effect a` **export** (e.g. `main :: Effect Unit`) is exposed to JS as a **thunk**
`() => a` — matching `Effect a ≃ () => a` — so importing the module does **not** run it; it
runs when you call it:

```javascript
import { exports } from "./output-wasm/Examples.Effect.Main/index.mjs";
exports.main();   // runs the effect now (prints), returns its result
```

(A pure value export like `answer :: Int` is still exposed as the value `42`, evaluated
once at load.) Auto-running a `main` on load — without an explicit call — is a possible
future loader flag.

### A wasm/wat foreign

A `foreign.wat` / `foreign.wasm` is **merged** into the program (`wasm-merge`), so it
speaks the **internal ABI directly** — no marshalling, no loader. Each function
**exports the base name** the import expects, taking/returning each value at its
internal representation (a raw `i32`/`f64` for `Int`/`Number`, an `eqref` otherwise):

```wat
;; foreign.wat for `Example.FFI` — provides `triple :: Int -> Int`
(module
  (func (export "triple") (param $n i32) (result i32)
    (i32.mul (local.get $n) (i32.const 3))))
```

Scalar foreigns are this simple. A wat foreign that builds or reads a **heap value**
(`$Str`, `$Vals`, `$Rec`, …) must declare those value types so they canonicalize with
the program's — that shared rec-group header is `ulib` territory (ADR 0010 / 0012).

### Notes

- A foreign's own arguments are **uncurried** (the import takes them all at once); a
  *function-typed* argument (`(Int -> Int) -> …`) arrives as a one-argument JS function.
- `foreign import`s cannot carry type-class constraints (PureScript forbids it), so
  every parameter/result is a concrete marshallable type or opaque.

## Calling a wasm export from JS

The entry module's top-level values are exported. The loader exposes them already
**marshalled**, so a JS caller passes and receives ordinary JS values:

```javascript
import { exports } from "./output-wasm/Example/index.mjs";

exports.greet("world");      // String -> String   → a JS string
exports.sumArr([1, 2, 3]);   // Array Int -> Int    → 6
exports.mkPoint(5);          // Int -> { x, y }     → { x: 5, y: 5 }
```

Under the hood the export wrapper exposes each parameter/result at its representation
(`i32`/`f64` raw, else `eqref`); the loader wraps it with the mirror-image glue
(arguments JS→wasm, result wasm→JS). A plain `Int -> Int` export is just an `i32`
function and can be called on the raw instance with no loader.

## What is not supported yet

- **JS function → wasm (closure direction 2).** A foreign that hands a JS *function*
  back to wasm — only reachable via a function nested in a result, or a callback
  *argument* to an export — is deferred. It needs a JS-side function registry plus a
  host-import trampoline so wasm can hold and re-enter a JS callable; the glue raises a
  clear error meanwhile. (A foreign that merely *returns a function*, `a -> (b -> c)`,
  is not this case: it is the same type as the uncurried `a -> b -> c`.)
- **JS-originated opaque values round-tripping through wasm.** A foreign whose result is
  an opaque value *created on the JS side* — most importantly `foreign import data` whose
  instances are JS objects, e.g. `Effect.Ref`'s `Ref` (`new` returns `{ value }`) — cannot
  be held by wasm and passed back to another foreign (`read`/`write`). `MOpaque` is carried
  as the internal GC `eqref`, but a JS object is an `externref`; returning it to a wasm
  `(result eqref)` import throws `TypeError: type incompatibility when transforming from/to
  JS` at run time. It is *not* caught at build time — the wasm builds and only traps when the
  value crosses. The general fix (carry JS-origin opaques as `externref`, boxed in a wasm
  struct) is blocked on a representation question: a *polymorphically*-opaque value that is
  really a wasm-GC value (e.g. the `s` read back out of a `Ref s` that holds an `Int`) must
  stay an `eqref` so it can still be `ref.cast` to its concrete type, yet a genuinely
  JS-native opaque must be `externref` — and the marshalling boundary cannot tell them apart.
  So such libraries are better provided **wasm-natively** (a runtime intrinsic or a ulib
  `foreign.wat`, ADR 0012) than through the JS ladder; `Effect.Ref` in particular is a pure
  mutable cell that needs no host at all and is slated for native support.
- **`Object a`** (dynamic string keys) — its representation differs from the
  static-label `$Rec` and needs a separate decision.
- **`main :: Effect Unit` auto-run on load** — an `Effect`-typed export is exposed as a
  callable thunk (`exports.main()` runs it); auto-running it on import, without an explicit
  call, is a possible loader flag. `EffectFnN`, `ST`, and `forE`/`whileE` are future work
  (ADR 0015).
- **bin build-integration test** — the production loader is smoke-verified, not yet
  covered by an automated end-to-end build test.
