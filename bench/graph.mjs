// Sweep every benchmark across its input sizes on three backends built from the
// SAME PureScript source — wasm (our GC backend), js-naive (purs's stock JS
// backend), js-es (purs-backend-es, the optimized JS people ship) — and write one
// `results/<name>.dat` per benchmark ("size  js-naive-ms  js-es-ms  wasm-ms") for
// gnuplot. A backend that overflows the stack (the JS backends have no TCO) records
// NaN, which gnuplot skips — so the curve simply stops.
//
// Driven by `graph.sh`, which builds all three backends first. The committed PNGs
// (results/*.png) are what the README embeds.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmBytes = readFileSync(fileURLToPath(new URL("./output-wasm/Bench.Main/index.wasm", import.meta.url)));
const wasmModule = await WebAssembly.compile(wasmBytes);
const jsNaive = await import("./output/Bench.Main/index.js");
const jsEs = await import("./output-js-es/Bench.Main/index.js");

async function wasmFn(name) {
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports[name];
}

// Run for ~1s so V8 tiers the function up to its optimizing compiler before timing
// (applies equally to wasm and JS — otherwise wasm is stuck on the baseline tier).
function warmUp(fn, arg, ms = 800) {
  const t0 = process.hrtime.bigint();
  do fn(arg);
  while (Number(process.hrtime.bigint() - t0) / 1e6 < ms);
}

// Adaptive timing: calibrate a repetition count for a stable batch, take the min
// over several trials (ns per call).
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

// time one backend at one size, in ms; NaN if it throws (e.g. a JS stack overflow)
function timeMs(fn, arg) {
  try {
    fn(arg);
    warmUp(fn, arg);
    return (nsPerOp(fn, arg) / 1e6).toFixed(4);
  } catch {
    return "NaN";
  }
}

// same benchmarks / sweeps as run.mjs
const benches = [
  { name: "fib", sizes: [20, 22, 24, 26, 28] },
  { name: "sumLoop", sizes: [200_000, 400_000, 600_000, 800_000, 1_000_000] },
  { name: "qsort", sizes: [500, 1000, 1500, 2000, 3000] },
  { name: "nqueens", sizes: [6, 7, 8, 9] },
  { name: "bintreeDfs", sizes: [12, 13, 14, 15, 16, 17] },
  { name: "bintreeBfs", sizes: [8, 9, 10, 11, 12] },
];

const outDir = fileURLToPath(new URL("./results", import.meta.url));
mkdirSync(outDir, { recursive: true });

console.log(`wasm: ${wasmBytes.length} bytes   node: ${process.version}\n`);
for (const b of benches) {
  const wfn = await wasmFn(b.name);
  const nfn = jsNaive[b.name];
  const efn = jsEs[b.name];
  const rows = b.sizes.map((size) => {
    const naive = timeMs(nfn, size);
    const es = timeMs(efn, size);
    const wasm = timeMs(wfn, size);
    return `${size} ${naive} ${es} ${wasm}`;
  });
  writeFileSync(`${outDir}/${b.name}.dat`, "# input-size  js-naive-ms  js-es-ms  wasm-ms\n" + rows.join("\n") + "\n");
  console.log(`${b.name.padEnd(11)} ${b.sizes.length} points`);
}
console.log(`\nwrote ${outDir}/*.dat`);
