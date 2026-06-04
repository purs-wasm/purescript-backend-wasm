// Cyclic-dictionary benchmark: `CountEffect.countTo :: Int -> Int` counts 0..n in the
// real `Effect` monad, exercising Effect's mutually-recursive instance dictionaries
// (functorEffect/applyEffect/bindEffect/monadEffect). The question this measures: does
// impurification (ADR 0015) + the simplifier collapse those cyclic dicts to a
// constant-stack tail loop with no residual closure/dispatch, the way the hand-rolled
// State monad collapses? Compares the same PureScript source across three backends:
//   * wasm     : our GC backend (output-wasm/CountEffect/index.wasm, optimized)
//   * js-naive : purs's stock JS backend (output, dictionary-passing + () => thunks)
//   * js-es    : purs-backend-es (output-js-es, the optimized JS people ship)
//
//   build:  spago build -p bench --output bench/output
//           node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e CountEffect
//           purs-backend-es build --corefn-dir ./bench/output --output-dir ./bench/output-js-es --int-tags
//   run:    node bench/count-effect.mjs
//
// `countTo n` returns `n`. The wasm function is called on a freshly-instantiated,
// warmed instance per size; the result is i32, so it needs no marshalling.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmBytes = readFileSync(fileURLToPath(new URL("./output-wasm/CountEffect/index.wasm", import.meta.url)));
const wasmModule = await WebAssembly.compile(wasmBytes);
const freshWasm = async () => (await WebAssembly.instantiate(wasmModule, {})).exports.countTo;
const naive = (await import("./output/CountEffect/index.js")).countTo;
const es = (await import("./output-js-es/CountEffect/index.js")).countTo;

const sizes = [1000, 2000, 4000, 8000, 16000, 32000, 64000];

function warmUp(fn, arg, ms = 500) {
  const t0 = process.hrtime.bigint();
  let n = 0;
  do {
    fn(arg);
    n++;
  } while (Number(process.hrtime.bigint() - t0) / 1e6 < ms);
  return n;
}

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
  ns == null ? "stack!" : ns >= 1e6 ? `${(ns / 1e6).toFixed(2)}ms` : ns >= 1e3 ? `${(ns / 1e3).toFixed(1)}us` : `${ns.toFixed(0)}ns`;

async function timeAt(make, n) {
  const fn = typeof make === "function" && make.length === 0 ? await make() : make;
  try {
    fn(n);
    warmUp(fn, n);
    return nsPerOp(fn, n);
  } catch (err) {
    return err instanceof RangeError ? null : Promise.reject(err);
  }
}

const wasmCheck = await freshWasm();
for (const n of [0, 100, 1000]) {
  const w = wasmCheck(n), nv = naive(n), e = es(n);
  if (w !== n || nv !== n || e !== n) {
    console.error(`MISMATCH at n=${n}: wasm=${w} naive=${nv} es=${e}`);
    process.exit(1);
  }
}

console.log(`wasm: ${wasmBytes.length} bytes   node: ${process.version}\n`);
console.log(
  `${"n".padStart(7)}  ${"wasm".padStart(9)}  ${"js-naive".padStart(9)}  ${"js-es".padStart(9)}   ${"wasm/es".padStart(8)}  ${"wasm/naive".padStart(10)}`
);

const ms = (ns) => (ns == null ? "NaN" : (ns / 1e6).toPrecision(6));

const rows = [];
for (const n of sizes) {
  const w = await timeAt(freshWasm, n);
  const nv = await timeAt(naive, n);
  const e = await timeAt(es, n);
  const ratio = (x) => (w == null || x == null ? "-" : `${(w / x).toFixed(2)}x`).padStart(8);
  console.log(
    `${String(n).padStart(7)}  ${fmt(w).padStart(9)}  ${fmt(nv).padStart(9)}  ${fmt(e).padStart(9)}   ${ratio(e)}  ${ratio(nv).padStart(10)}`
  );
  rows.push(`${n} ${ms(nv)} ${ms(e)} ${ms(w)}`);
}

console.log("\nwasm/es < 1.0 = wasm faster than optimized JS;  > 1.0 = JS faster.");
console.log('"stack!" = JS-style O(n) call stack overflowed (the Effect bind chain is not TCO\'d).');

const outDir = fileURLToPath(new URL("./results", import.meta.url));
mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/count-effect.dat`, "# input-size  js-naive-ms  js-es-ms  wasm-ms\n" + rows.join("\n") + "\n");
console.log(`\nwrote ${outDir}/count-effect.dat`);
