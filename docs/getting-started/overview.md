# Overview

Purs-wasm is an experimental compiler from PureScript CoreFn to WebAssembly. According to
our benchmarks, the compiled wasm typically runs faster than the JavaScript emitted by both
the stock `purs` compiler and
[purs-backend-es](https://github.com/aristanetworks/purescript-backend-optimizer).

## Installation

Coming soon...

## How to Use It

purs-wasm is a PureScript compiler **backend**; it does not consume PureScript source code
itself. That is the job of the official PureScript compiler, `purs`. purs-wasm takes as its
input the **intermediate artifacts** that `purs` produces during compilation:

- **CoreFn** — the functional core of the PureScript language
- **Externs** — the public interface of a module's exported declarations, including types,
  type classes and functions

In other words, to compile your PureScript project to WebAssembly with purs-wasm, you must
first compile your PureScript sources with `purs` so that the CoreFn and externs of every
module are laid out in a known directory.

The most common way to do this is with [**spago**](https://github.com/purescript/spago),
the de-facto standard PureScript build tool:

```sh
spago build
```

> **Note** purs-wasm currently does not support projects that do not use spago.

Once the build succeeds without errors, you are ready. The following command compiles your
PureScript application to wasm:

```sh
purs-wasm build -e Main
```

This produces the build artifacts, including the wasm, under `output-wasm/`:

```plain
output-wasm/
├── index.wasm        # your application compiled to wasm
├── index.mjs         # the JavaScript loader (see below)
├── marshal.js        # shared marshalling glue
└── foreign/
    └── Effect.Console.js   # one file per JS foreign module your app uses
```

`index.wasm` is your PureScript application compiled to wasm. To run it, you need to:

- inject some JS-native functions (e.g. `console.log`, `Math.random`),
- wrap values to convert between the wasm runtime representation and the JavaScript
  representation,
- instantiate the wasm module.

`index.mjs` does all of this for you. The following code runs your PureScript `main`
(assume it has type `Effect Unit`):

```js
import app from "./output-wasm/index.mjs";
app.main();
```

> **Note** A `--platform standalone` build that uses no JS foreigns emits a single,
> self-contained `index.wasm` with no loader.

## Build Wasm for Your Existing App, Today

As you may know, in PureScript even basic operations such as integer arithmetic are FFI
calls into functions defined in JavaScript. This is what makes PureScript's
backend-agnostic language design possible, but it is also a headache for anyone who wants
to build or use a non-JS backend: every foreign module would otherwise have to be
reimplemented in the target language.

purs-wasm mitigates this: when a foreign import has no corresponding `foreign.wat`, it
falls back to the conventional `foreign.js`. This partially solves the problem and lets you
build your existing PureScript app for wasm right away.

That said, not every JavaScript can be turned into wasm — there are some constraints on the
JS code you can call through the FFI. See the *Performance and Limitations* page for
details.

## Compiler options

- `-e | --entry <Module>` — the name of an entry module (whose exports are kept). Required;
  may be given several times.
- `-I | --input <dir>` — the directory purs-wasm searches for `purs`'s artifacts
  (`corefn.json` and `externs.cbor`). Defaults to `output`.
- `-O | --output <dir>` — the directory the build artifacts are written to. Defaults to
  `output-wasm`.
- `-p | --platform <node|browser|standalone>` — deployment target. `node` / `browser` emit
  a single wasm plus a JS loader (the loader differs only in how it loads the wasm: Node reads
  the file, the browser `fetch`es it); `standalone` emits a self-contained single wasm with no
  loader. Defaults to `node`.
- `-E | --executable` — produce a runnable: the JS loader calls the entry module's `main` on
  load, so running the loader runs the program. Requires `main :: Effect Unit` and
  `--platform=node` or `browser` (not valid with `standalone`).
- `-t | --text` — emit the WebAssembly text format (`.wat`) instead of a binary `.wasm`.
- `-g | --debug` — debug build: skip the Binaryen optimizer (keeps the wasm close to the
  emitted IR).
- `--no-opt` — skip the middle-end optimization (dictionary elimination); lambda lifting
  still runs. Useful for an unoptimized benchmark baseline.
- `--no-js-fallback` — fail the build instead of falling back to a `foreign.js` for a
  foreign import that has no `foreign.wat` provider.
- `--dump-mir <Module>` — dump how the module's middle IR changes after every optimizer
  sub-stage to `<output>/<Module>.mir.txt` (debugging).
