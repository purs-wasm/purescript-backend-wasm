# Performance and Limitations

There are many reasons to compile PureScript to WebAssembly, but the biggest is probably
performance. As purs-wasm evolves, we maintain a large suite of benchmarks to guarantee — on
an evidence basis — that we do not introduce performance regressions unintentionally.

## Benchmarks

The same PureScript source compiled three ways — wasm (this backend), the stock `purs` JS
backend, and [`purs-backend-es`](https://github.com/aristanetworks/purescript-backend-optimizer) —
timed on one machine (lower is better):

| | |
| - | - |
| ![fib](https://purs-wasm.github.io/documentation/images/bench/fib.png) | ![sumLoop](https://purs-wasm.github.io/documentation/images/bench/sumLoop.png) |
| ![qsort](https://purs-wasm.github.io/documentation/images/bench/qsort.png) | ![nqueens](https://purs-wasm.github.io/documentation/images/bench/nqueens.png) |
| ![bintreeDfs](https://purs-wasm.github.io/documentation/images/bench/bintreeDfs.png) | ![bintreeBfs](https://purs-wasm.github.io/documentation/images/bench/bintreeBfs.png) |
| ![mapFold](https://purs-wasm.github.io/documentation/images/bench/mapFold.png) | ![mapFoldArray](https://purs-wasm.github.io/documentation/images/bench/mapFoldArray.png) |
| ![CountState](https://purs-wasm.github.io/documentation/images/bench/count-state.png) | ![CountEffect](https://purs-wasm.github.io/documentation/images/bench/count-effect.png) |
| ![curry](https://purs-wasm.github.io/documentation/images/bench/curry.png) | |

wasm is fastest on the algorithmic benchmarks and completes the deep-recursion / monadic
sweeps where the JS backends overflow the call stack. The library higher-order benchmarks
(`mapFold` / `mapFoldArray`) are the current frontier; `Free` / `Run` is the one case wasm
trails (see below).

## Known Limitations

In most cases, wasm compiled by purs-wasm performs better than running the same code as
JavaScript — but not always. The known cases are below.

### Monomorphization is not employed

Because there is no monomorphization, recursion across a polymorphic data type is slow: each
element is boxed rather than stored unboxed.

### `Free` / `Run` monadic programs are not very performant

Code written with `Free` / `Run` (interpreter-style monads) is currently slow: the per-step
allocation of the `Free` / `VariantF` cells dominates, and the optimizer does not yet
specialize the interpreter. The CountRun benchmark (a `Run`/`State` loop) shows wasm trailing
`purs-backend-es` by ~1.6× — the one sweep where wasm is not ahead:

![CountRun: Run/Free interpreter iterations across backends (log-log)](https://purs-wasm.github.io/documentation/images/bench/count-run.png)

### The JS FFI is a marshalling boundary

As you know, the FFI is a gateway between the PureScript and JavaScript worlds. Because
PureScript's compilation target is JavaScript, values exchanged through the FFI share the
same runtime representation in both the PS and JS worlds. That is, in JS-backend PureScript
the FFI is simply a "public road" between the two worlds: a value defined in either world
passes straight through to the other side.

In Wasm-backend PureScript, however, the JS world and the wasm world follow completely
different disciplines. A JS object / array / closure is a `struct` / `eqref` in the wasm
world — not the JS runtime representation. So when crossing the FFI bridge, values must be
converted to the representation appropriate for each world. We call this conversion
**marshalling**.

> **Note** For how each PureScript value is represented as a Wasm-GC value at runtime, see
> [runtime-representation](../developers-guide/runtime-representation.md).

Currently, purs-wasm marshals the following values properly, so JS values can be handled
safely on the PS side and vice versa:

- `Int`
- `Char`
- `Boolean`
- `Number`
- `String`
- an `Array` whose elements are themselves marshallable
- a `Record` whose members are themselves marshallable
- an `Effect` that yields a marshallable type
- a function whose arguments and result are marshallable (with restrictions — see below)

When you `foreign import` a type not covered above, it becomes merely an opaque reference.

This entails an important restriction: **if your JS-backend PureScript app has FFI into code
that relies on the JS runtime representation internally, you cannot port it to Wasm-backend
PureScript.** For example, the representation-equality tricks often used in JS-backend
PureScript — such as touching a PureScript record as a raw JS object in `foreign.js` — are
not possible.

### Restrictions on function marshalling

A wasm closure passed *out* to JavaScript works (for example, a callback you hand to a JS
foreign). The reverse direction — a **JavaScript function passed *into* wasm**, as a callback
argument or nested inside a foreign's result — cannot currently be marshalled into a callable
wasm closure.

For instance, suppose you want to call this PureScript function from JavaScript:

```purs
applyTwice :: (Int -> Int) -> Int -> Int
applyTwice f x = f (f x)
```

It builds fine, and you would invoke it through the JS loader like this:

```js
import { exports } from "./output-wasm/index.mjs";
exports.applyTwice((n) => n + 1, 5);
```

But because `applyTwice`'s first argument — a JS function — cannot be marshalled, it throws
at run time:

```text
Error: FFI: marshalling a JS function into wasm is not yet supported (ADR 0014, closure direction 2)
```

The same happens when a foreign's *result* nests a function inside a data structure:

```purs
foreign import createValidator :: Config -> { validate :: String -> Boolean }
```

```js
export const createValidator = (cfg) => ({
  validate: (s) => s.length > 0  // a record field that is a JS function
});
```

Marshalling the result record from JS to wasm tries to turn the `validate` field's JS
function into a wasm closure, and throws. Note that both cases build successfully — the error
surfaces only when the value actually crosses the boundary.

> **Note** A confusingly similar case that *does* work:
>
> ```purs
> foreign import mapJS :: (Int -> Int) -> Array Int -> Array Int
> ```
>
> Here the wasm closure is marshalled *out* to JavaScript and applied on the JS side. No
> JavaScript-function-into-wasm crossing occurs, so there is no problem.
>
> Rule of thumb: **design your APIs so that first-class functions cross in the wasm → JS
> direction only.**

*Tracking Issue: [#12](https://github.com/purs-wasm/purescript-backend-wasm/issues/12)*

### Tail calls through a closure value are not stack-safe

Tail-call elimination applies only to direct calls to *known* top-level functions; a tail
call made through an opaque closure value compiles to a normal `call_ref` and still grows the
stack. In practice this rarely bites — a self-recursive function and a `where go = …` loop
are lambda-lifted to top-level functions and run in constant stack (so does `Effect`
recursion; see *Differences from JavaScript-backend PureScript*). The gap remains only for a
tail recursion routed through a first-class closure the optimizer could not resolve to a
known function.

*Tracking Issue: [#18](https://github.com/purs-wasm/purescript-backend-wasm/issues/18)*

### `Object a` is currently not supported

`Foreign.Object` (`Object a`, a homogeneous JS map) is not yet supported at the FFI
boundary.

### `Aff` is not supported

`Aff` is not supported: its asynchronous scheduler relies on FFI that purs-wasm does not
provide.

### A top-level value computed through a re-entrant JS foreign traps at load

A **top-level binding (CAF)** is computed once **at instantiation** — its value is stored in a
module global the rest of the program reads (ADR 0006). If such a binding's computation
transitively calls a **JS foreign that calls back into wasm** — a higher-order `foreign.js` that
receives wasm closures, e.g. `Data.Unfoldable.unfoldrArrayImpl`, which `record-studio`'s
`keys` / `shrink` reach — it **traps at load** with `TypeError: Cannot read properties of
undefined (reading 'exports')`. The callback re-enters the instance's exports, but the loader binds
the instance only *after* `WebAssembly.instantiate` returns, while initialization runs *during* it;
WebAssembly does not let an instance's exports be re-entered from JS during its own start.

This only affects **top-level** values whose initializer routes through such a foreign — most record
metaprogramming (including building records with `record-studio`) is fine when run from a function.

**Workaround:** compute the value inside `main` (or any function called after load), not as a
top-level binding:

```purescript
-- traps at load:
result :: SomeRecord
result = shrink (alice // { bio: "…" })

main :: Effect Unit
main = logShow result

-- works — computed after load:
main :: Effect Unit
main = logShow (shrink (alice // { bio: "…" }))
```

The workaround helps only when the top-level value is in **your** code. If a **library** holds
such a binding internally — `record-studio`, whose `keys`/`shrink` route through
`unfoldrArrayImpl`, is one — moving your own code into `main` does not help, and the program traps
at load until the fix lands (the `examples/record-meta` example is kept as a repro of exactly this).

The fix (the loader runs initialization *after* instantiation, instead of the wasm start section)
rides along with the streaming-compilation work — see
[ADR 0006](https://github.com/purs-wasm/purescript-backend-wasm/blob/main/docs/design-decisions/0006-top-level-value-bindings-as-globals.md)
and [ADR 0021](https://github.com/purs-wasm/purescript-backend-wasm/blob/main/docs/design-decisions/0021-streaming-dependency-ordered-wpo.md).
