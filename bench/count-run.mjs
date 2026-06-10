// Run/State benchmark: `CountRun.countTo :: Int -> Int` over purescript-run's STATE effect —
// the Run/Free interpreter loop, including the eta-expanded point-free recursive `loop` bindings
// in `Run.run`/`runState` (so each step recomputes the `resume f pure` closure that a shared
// binding would build once). Mirrors `count-state.mjs` (the hand-rolled `State` analogue) so the
// two are directly comparable, and compares the same source across three backends:
//   * wasm     : our GC backend (output-wasm-run/index.wasm, optimized)
//   * js-naive : purs's stock JS backend (output, dictionary-passing)
//   * js-es    : purs-backend-es (output-js-es, the optimized JS people ship)
//
//   build:  spago build -p bench --output bench/output
//           node ./purs-wasm/index.dev.js build -I ./bench/output -O ./bench/output-wasm-run -e CountRun
//           purs-backend-es build --corefn-dir ./bench/output --output-dir ./bench/output-js-es --int-tags
//   run:    node bench/count-run.mjs
//
// The wasm imports `Partial._crashWith` (the impossible empty-variant case in Run's VariantF
// matching); it is never hit by correct code, so a throwing stub satisfies instantiation. The
// `countTo` export is i32-in/i32-out, so the raw call needs no marshalling.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const partialStub = { Partial: { _crashWith: () => { throw new Error("partial pattern match"); } } };
const wasmBytes = readFileSync(fileURLToPath(new URL("./output-wasm-run/index.wasm", import.meta.url)));
const wasmModule = await WebAssembly.compile(wasmBytes);
const freshWasm = async () => (await WebAssembly.instantiate(wasmModule, partialStub)).exports.countTo;
const naive = (await import("./output/CountRun/index.js")).countTo;
const es = (await import("./output-js-es/CountRun/index.js")).countTo;

const sizes = [1000, 2000, 4000, 8000, 16000, 32000, 64000];

function warmUp(fn, arg, ms = 500) {
  const t0 = process.hrtime.bigint();
  let n = 0;
  do { fn(arg); n++; } while (Number(process.hrtime.bigint() - t0) / 1e6 < ms);
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

const wasm = await freshWasm();
// correctness up front: countTo n == n on every backend
for (const fn of [wasm, naive, es]) {
  for (const n of [0, 1, 100]) if (fn(n) !== n) throw new Error(`countTo(${n}) != ${n}`);
}
for (const fn of [wasm, naive, es]) warmUp(fn, 4000);

console.log("CountRun (Run/State) — ns/op, and wasm vs js-es ratio:");
console.log("  n        wasm        js-naive    js-es       wasm/js-es");
for (const n of sizes) {
  const w = nsPerOp(wasm, n);
  const na = nsPerOp(naive, n);
  const e = nsPerOp(es, n);
  const pad = (x, w = 11) => x.padEnd(w);
  console.log(
    "  " + pad(String(n), 9) +
    pad((w / 1e3).toFixed(1) + "us") +
    pad((na / 1e3).toFixed(1) + "us") +
    pad((e / 1e3).toFixed(1) + "us") +
    (w / e).toFixed(2) + "x",
  );
}
