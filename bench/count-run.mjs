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
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
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

// Run/Free is stack-safe on every backend, so no curve should drop out; the try/catch is
// cheap insurance (an overflow becomes NaN, which gnuplot skips via `missing "NaN"`).
const safeNs = (fn, n) => { try { return nsPerOp(fn, n); } catch (_) { return NaN; } };

console.log("CountRun (Run/State) — ns/op, and wasm vs js-es ratio:");
console.log("  n        wasm        js-naive    js-es       wasm/js-es");
const rows = [];
for (const n of sizes) {
  const w = safeNs(wasm, n);
  const na = safeNs(naive, n);
  const e = safeNs(es, n);
  const pad = (x, wd = 11) => x.padEnd(wd);
  const us = (x) => Number.isFinite(x) ? (x / 1e3).toFixed(1) + "us" : "stack!";
  console.log(
    "  " + pad(String(n), 9) + pad(us(w)) + pad(us(na)) + pad(us(e)) +
    (Number.isFinite(w) && Number.isFinite(e) ? (w / e).toFixed(2) + "x" : "-"),
  );
  // .dat columns mirror count-effect: "size  js-naive-ms  js-es-ms  wasm-ms"
  const ms = (x) => Number.isFinite(x) ? (x / 1e6).toFixed(6) : "NaN";
  rows.push(`${n}  ${ms(na)}  ${ms(e)}  ${ms(w)}`);
}

const outDir = fileURLToPath(new URL("./results", import.meta.url));
mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/count-run.dat`, "# input-size  js-naive-ms  js-es-ms  wasm-ms\n" + rows.join("\n") + "\n");
console.log(`\nwrote ${outDir}/count-run.dat`);
