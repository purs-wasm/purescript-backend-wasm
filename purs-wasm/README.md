# purs-wasm

An experimental **WebAssembly (GC) backend for the PureScript compiler**. It consumes the CoreFn
and externs that `purs` emits and links them into a single self-contained `.wasm` (plus an optional
JS loader). Compiled output often runs faster than the JavaScript from both the stock `purs` backend
and `purs-backend-es`.

## Install

```sh
npm i -D purs-wasm
```

This also installs [`binaryen`](https://www.npmjs.com/package/binaryen) (the `wasm-merge` / `wasm-as`
tools the build links with). You also need the PureScript toolchain (`purs` /
[spago](https://github.com/purescript/spago)) and **Node.js 22 or newer** (the output uses
WebAssembly GC).

## Use

```sh
spago build                       # produce CoreFn + externs under ./output
npx purs-wasm build -e Main -E    # link to ./output-wasm/ (-E: run main on load)
node output-wasm/index.mjs        # run
```

`purs-wasm build --help` lists all options (`-p/--platform`, `-E/--executable`, …).

## Documentation

Full getting-started guide, the developer guide, and the design decisions:
<https://purs-wasm.github.io/documentation/>

## License

MIT © Katsujukou Kineya
