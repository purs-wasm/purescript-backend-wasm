// Run the wasm emitted by `purs-backend-wasm build`.
//
//   1. build it:  node ../bin/index.dev.js build -I ./output -O ./output-wasm -e Index
//   2. run it:    node run.mjs
//
// The module is self-contained — `Lib`'s `foreign import`s (addI/subI/eqI) are
// compiled to wasm intrinsics, not host imports — so it instantiates with an
// empty import object. (It uses Wasm GC, so a recent runtime is required; Node 22+
// works out of the box.)

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmPath = fileURLToPath(new URL("./output-wasm/index.wasm", import.meta.url));
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const exports = instance.exports;

console.log("wasm exports:", Object.keys(exports).join(", ") || "(none)");

// `Index.fib` is the (0-indexed) Fibonacci sequence. PureScript `Int` is 32-bit,
// and the backend's `addI` is `i32.add`, so results wrap modulo 2^32 once they
// exceed 2^31 - 1 (around fib(47)) — exactly as PureScript's own `Int` does.
if (typeof exports.fib === "function") {
  const fibExact = (n) => {
    let a = 0n, b = 1n;
    for (let i = 0; i < n; i++) [a, b] = [b, a + b];
    return a;
  };
  const I32_MAX = 2147483647n;
  for (const n of [1, 5, 10, 46, 47, 100]) {
    const got = exports.fib(n);
    const exact = fibExact(n);
    const note = exact > I32_MAX ? "   ⚠ exceeds i32, wraps" : "";
    console.log(`fib(${n}) = ${got}   (exact ${exact})${note}`);
  }
}
