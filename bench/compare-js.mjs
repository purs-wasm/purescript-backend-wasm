// Cross-backend comparison: time each `Int -> Int` benchmark on three backends
// built from the *same* PureScript source —
//   * wasm     : our GC backend (output-wasm, optimized)
//   * js-naive : purs's stock JS backend (output, dictionary-passing)
//   * js-es    : purs-backend-es (output-js-es, the optimized JS people ship)
// using the same adaptive timer as run.mjs, so the columns are directly comparable.
//
//   build first:  npm run build          (wasm)
//                 npm run build:ps        (js-naive, into ./output)
//                 purs-backend-es build --corefn-dir ./output --output-dir ./output-js-es --int-tags
//   run:          node compare-js.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmBytes = readFileSync(fileURLToPath(new URL("./output-wasm/index.wasm", import.meta.url)));
const jsNaive = await import("./output/Bench.Main/index.js");
const jsEs = await import("./output-js-es/Bench.Main/index.js");

// Compile the wasm module ONCE and reuse it. Re-instantiating from raw bytes per
// measurement (as run.mjs does, to avoid cross-benchmark heap pollution) forces V8
// to recompile and keeps the code on the baseline (Liftoff) tier — measuring that
// against fully JIT-compiled (TurboFan) JS is apples-to-oranges. Here each benchmark
// runs on a single instance, warmed long enough for V8 to tier wasm up to TurboFan.
const wasmModule = await WebAssembly.compile(wasmBytes);
async function freshWasmFn(name) {
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports[name];
}

// Run the function in a tight loop for ~1s of wall-clock so V8's background
// compiler tiers it up before we measure (applies equally to wasm and JS).
function warmUp(fn, arg, ms = 1000) {
  const t0 = process.hrtime.bigint();
  let n = 0;
  do {
    fn(arg);
    n++;
  } while (Number(process.hrtime.bigint() - t0) / 1e6 < ms);
  return n;
}

// Same adaptive timing as run.mjs: calibrate reps for a ~30ms+ batch, take the min
// over several trials (ns per call). (Warmup is done separately, above.)
function nsPerOp(fn, arg) {
  let reps = 1;
  for (;;) {
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < reps; i++) fn(arg);
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    if (ms >= 30 || reps >= 5e8) break;
    reps = Math.max(reps + 1, Math.ceil((reps * 40) / Math.max(ms, 0.01)));
  }
  let best = Infinity;
  for (let t = 0; t < 5; t++) {
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < reps; i++) fn(arg);
    best = Math.min(best, Number(process.hrtime.bigint() - t0) / reps);
  }
  return best;
}

const fmt = (ns) =>
  ns >= 1e6 ? `${(ns / 1e6).toFixed(1)}ms` : ns >= 1e3 ? `${(ns / 1e3).toFixed(1)}us` : `${ns.toFixed(0)}ns`;

// largest input from each sweep in run.mjs
const benches = [
  { name: "fib", size: 28 },
  { name: "sumLoop", size: 1_000_000 },
  { name: "qsort", size: 3000 },
  { name: "nqueens", size: 9 },
  { name: "bintreeDfs", size: 17 },
  { name: "bintreeBfs", size: 12 },
  { name: "mapFold", size: 500 },
  { name: "mapFoldArray", size: 500 },
  { name: "mapFoldWasmArray", size: 500 },
];

console.log(`wasm: ${wasmBytes.length} bytes   node: ${process.version}\n`);
console.log(
  `${"bench".padEnd(11)} ${"size".padStart(9)}  ${"wasm".padStart(9)}  ${"js-naive".padStart(9)}  ${"js-es".padStart(9)}   wasm/es   wasm/naive`
);

for (const b of benches) {
  const wfn = await freshWasmFn(b.name);
  const nfn = jsNaive[b.name];
  const efn = jsEs[b.name];

  // Time one backend: confirm its checksum, warm to tier-up, then measure.
  // A naive-JS deep recursion can blow the JS stack (no TCO) — report that.
  const time = (fn) => {
    try {
      const r = fn(b.size);
      warmUp(fn, b.size);
      return { r, ns: nsPerOp(fn, b.size) };
    } catch (err) {
      return { r: null, ns: null, err: err instanceof RangeError ? "stack!" : "err" };
    }
  };

  const W = time(wfn), N = time(nfn), E = time(efn);
  const agree =
    W.r != null && N.r != null && E.r != null && (W.r !== N.r || N.r !== E.r)
      ? `  !! MISMATCH w=${W.r} n=${N.r} e=${E.r}`
      : "";
  const col = (X) => (X.ns == null ? X.err : fmt(X.ns)).padStart(9);
  const rat = (X) => (X.ns == null ? "-" : (W.ns / X.ns).toFixed(2) + "x").padStart(8);
  console.log(
    `${b.name.padEnd(11)} ${String(b.size).padStart(9)}  ${col(W)}  ${col(N)}  ${col(E)}   ${rat(E)}   ${rat(N)}${agree}`
  );
}
console.log("\nwasm/es < 1.0 = wasm faster than optimized JS;  > 1.0 = JS faster.");
