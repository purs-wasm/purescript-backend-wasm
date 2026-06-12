# FFI: Writing Foreigns and Calling Exports

PureScript's FFI works on the Wasm backend too. This page shows how to write a `foreign
import`, and how to call your compiled wasm exports from JavaScript.

Before reaching for the FFI, read *Differences from JavaScript-backend PureScript* — on
wasm, writing a foreign purely **for performance** usually backfires (it is an opaque
barrier to the optimizer). The FFI is for genuine host effects (e.g. `console.log`) and for
reusing existing JavaScript. For how a foreign import is resolved and when it falls back to
JavaScript, see *Module Resolution and `ulib`*; for what can and cannot cross the boundary,
see *Performance and Limitations*.

## Choosing an implementation

You provide an implementation file next to your module (as usual — `purs` carries it into
the build input). You have three choices, in resolution order:

| File | When to use | Result |
| - | - | - |
| `foreign.wasm` | a precompiled wasm provider | self-contained `index.wasm` |
| `foreign.wat` | a self-contained, platform-agnostic foreign, or a low-level wasm leaf primitive, written in WebAssembly text | self-contained `index.wasm` |
| `foreign.js` | reuse an existing JavaScript implementation unchanged | `index.wasm` + the loader (`index.mjs`, `marshal.js`, `foreign/<Module>.js`) |

Choose **wat/wasm** for a self-contained or platform-agnostic foreign (this is how some of
the `ulib` core packages are built). Choose **js** to reuse JavaScript. If you provide none
and the name is not a built-in, the call traps.

## Writing a JS foreign

Declare the `foreign import` and write the implementation as ordinary, curried PureScript
FFI. The loader converts (**marshals**) values between the wasm and JS representations, so
your JavaScript sees plain JS values:

```purescript
module Example.FFI where

foreign import shout :: String -> String
```

```javascript
// foreign.js — the foreign sees plain JS values; the loader marshals String ↔ string
export const shout = (s) => s.toUpperCase();
```

The build emits a loader (`index.mjs`) that imports `foreign.js`, wraps `shout` with
marshalling, and instantiates the module. A program with **no** JS foreigns emits no loader —
it stays a single self-contained `index.wasm`.

## Writing an effectful foreign

A `foreign import` whose result is `Effect a` is a side-effecting host call (the
`console.log` shape). Write it as the usual curried FFI — take the value argument and return
a thunk:

```purescript
module Example.Hello where

import Effect (Effect)

foreign import log :: String -> Effect Unit
```

```javascript
// foreign.js — the standard `s => () => …` shape
export const log = (s) => () => console.log(s);
```

When wasm performs `log "hi"`, the loader applies the value argument and runs the returned
thunk on the JS side (`log("hi")()`), marshalling only the inner result. The side effect
happens at the boundary; wasm never has to hold or re-enter a JS function. The optimizer
recognises `log` as effectful and will not drop, reorder, or duplicate the call.

An `Effect a` **export** (e.g. `main :: Effect Unit`) is exposed to JS as a **thunk**
`() => a`, so importing the module does **not** run it — it runs when you call it:

```javascript
import app from "./output-wasm/index.mjs";
app.main();   // runs the effect now (e.g. prints), returns its result
```

(A pure value export like `answer :: Int` is exposed as the value `42`, evaluated once at
load.)

## Writing a wat foreign

A `foreign.wat` is merged directly into your program, so it needs no loader and no
marshalling — but it must speak wasm's internal representation: a raw `i32`/`f64` for
`Int`/`Number`, and a heap reference otherwise. A scalar foreign is simple:

```wat
;; foreign.wat for `Example.FFI` — provides `triple :: Int -> Int`
(module
  (func (export "triple") (param $n i32) (result i32)
    (i32.mul (local.get $n) (i32.const 3))))
```

A wat foreign that builds or reads a heap value (a string, array, or record) is for library
authors and needs the shared runtime types — see the contributor docs. As a rule, if you are
writing low-level wasm, prefer the `Wasm.*` modules from `wasm-base` over a hand-written
`foreign.wat` where possible.

## Calling a wasm export from JS

The entry module's top-level values are exported, already **marshalled**, so a JS caller
passes and receives ordinary JS values:

```javascript
import { exports } from "./output-wasm/index.mjs";

exports.greet("world");      // String -> String   → a JS string
exports.sumArr([1, 2, 3]);   // Array Int -> Int    → 6
exports.mkPoint(5);          // Int -> { x, y }     → { x: 5, y: 5 }
```

A plain `Int -> Int` export is just an `i32` function and can be called on the raw instance
even without the loader.

### Best practice: export only transparent, JS-safe types

The export marshalling is driven by each parameter/result's **type**:
`Int`/`Number`/`Boolean`/`String`/`Array`/`Record`/function. An **opaque** type — a
`newtype`/`data` the marshaller does not unfold, *including a function newtype* — carries no
information about what it wraps, so it cannot be marshalled. Exporting such a value directly
is fail-safe but unsupported: it either coincidentally matches the raw fallback or cleanly
traps, but it is not a reliable JS surface.

```purescript
newtype SafeAPI = SafeAPI (Int -> Int)
runSafe :: SafeAPI -> Int -> Int
runSafe (SafeAPI f) = f

foo   :: SafeAPI       -- ✗ don't export directly: `SafeAPI` is opaque, so the glue is blind
fooJS :: Int -> Int    -- ✓ export this: a transparent, JS-safe bridge
fooJS = runSafe foo
```

This is the same discipline the PureScript **JS backend** encourages: across the boundary,
expose only JS-safe values — `Int`/`Number`/`Boolean`/`String` and functions over them —
and bridge opaque/abstract types through a runner. Point-free top-levels are fine
(`inc = add 1` exports as a working `Int -> Int`).

For the types that can cross the boundary, the restrictions on function and opaque values,
and the gaps (`Object a`, `Aff`), see *Performance and Limitations*.
