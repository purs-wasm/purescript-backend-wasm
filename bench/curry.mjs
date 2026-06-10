// Curry-vs-uncurry benchmark: `BenchCurry.{curryDispatch,uncurryDispatch} :: Int -> Int`
// compute the *same* checksum, one keeping the ternary op curried (`op(a)(b)(c)`), the
// other through `Fn3` (`op(a, b, c)`). Sweeping the iteration count `n`, it measures the
// per-backend currying tax — the curry/uncurry slowdown ratio — on the same PureScript
// source across three backends:
//   * wasm     : our GC backend (output-wasm-curry/index.wasm, optimized)
//   * js-naive : purs's stock JS backend (output, dictionary-passing)
//   * js-es    : purs-backend-es (output-js-es, the optimized JS people ship)
//
//   build:  spago build -p bench --output bench/output
//           node ./purs-wasm/index.dev.js build -I ./bench/output -O ./bench/output-wasm-curry -e BenchCurry
//           purs-backend-es build --corefn-dir ./bench/output --output-dir ./bench/output-js-es --int-tags
//   run:    node bench/curry.mjs
//
// The headline is the ratio, not the absolute time. On wasm `mkFn3` is the identity and
// `runFn3` is the saturated apply (the same lowering a saturated curried application
// already gets), so curried code carries no extra cost (ratio ~1.0) *by construction*.
// In JS it depends on the codegen + JIT: V8's escape analysis eliminates the stock purs
// backend's intermediate closures (ratio ~1.0), but purs-backend-es still pays ~3x for
// curried application — so the wasm guarantee is the robust property, not a JS universal.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmBytes = readFileSync(fileURLToPath(new URL("./output-wasm-curry/index.wasm", import.meta.url)));
const wasmModule = await WebAssembly.compile(wasmBytes);
// Both exports are i32-in/i32-out, so the raw exports need no marshalling. One warmed
// instance per backend (reused across sizes) so V8 tiers the wasm up to TurboFan —
// re-instantiating per call would keep it on the Liftoff tier (see compare-js.mjs).
const wasm = (await WebAssembly.instantiate(wasmModule, {})).exports;
const naive = await import("./output/BenchCurry/index.js");
const es = await import("./output-js-es/BenchCurry/index.js");

const backends = [
  { key: "wasm", curry: wasm.curryDispatch, uncurry: wasm.uncurryDispatch },
  { key: "naive", curry: naive.curryDispatch, uncurry: naive.uncurryDispatch },
  { key: "es", curry: es.curryDispatch, uncurry: es.uncurryDispatch },
];

// Kept ≤ ~1M: past that the dictionary-passing js-naive backend becomes GC-bound and
// its absolute times swamp the marginal closure-allocation cost, washing the curry tax
// out as noise. In this range all three backends sit in their steady state.
const sizes = [50_000, 100_000, 200_000, 400_000, 800_000];

// Correctness: the curried and uncurried banks compute identical bodies, so every
// function on every backend must agree at each check size (a real check — a wrong
// dispatch or a dropped arg would diverge here).
for (const n of [0, 1000, 100_000]) {
  const vals = backends.flatMap((b) => [b.curry(n), b.uncurry(n)]);
  if (!vals.every((v) => v === vals[0])) {
    console.error(`MISMATCH at n=${n}: ${backends.map((b) => `${b.key}=${b.curry(n)}/${b.uncurry(n)}`).join(" ")}`);
    process.exit(1);
  }
}

// Warm long enough for V8 to tier wasm/JS up before measuring (applies to both).
function warmUp(fn, arg, ms = 500) {
  const t0 = process.hrtime.bigint();
  do fn(arg);
  while (Number(process.hrtime.bigint() - t0) / 1e6 < ms);
}

// Min over single calls (each invocation is already ms-scale at these sizes). Unlike a
// rep-batched throughput timer, the min isolates a GC-free invocation — so it measures
// the *marginal* per-call closure-allocation cost (the currying tax) rather than letting
// the dictionary-passing js-naive backend's GC churn amortize it away. ns per call.
function nsPerOp(fn, arg) {
  let best = Infinity;
  for (let t = 0; t < 21; t++) {
    const t0 = process.hrtime.bigint();
    fn(arg);
    best = Math.min(best, Number(process.hrtime.bigint() - t0));
  }
  return best;
}

const fmt = (ns) => (ns >= 1e6 ? `${(ns / 1e6).toFixed(1)}ms` : ns >= 1e3 ? `${(ns / 1e3).toFixed(1)}us` : `${ns.toFixed(0)}ns`);

console.log(`wasm: ${wasmBytes.length} bytes   node: ${process.version}\n`);
console.log(
  `${"n".padStart(9)}   ` +
    backends.map((b) => `${(b.key + " c").padStart(8)} ${(b.key + " u").padStart(8)} ${"c/u".padStart(6)}`).join("  ")
);

// data file for plot-curry.gp: "size  wasm-ratio  naive-ratio  es-ratio" — the curry /
// uncurry slowdown per backend (the currying tax; ~1.0 means no extra cost).
const rows = [];
for (const n of sizes) {
  const cells = [];
  const ratios = [];
  for (const b of backends) {
    // Warm BOTH functions before timing either, so V8 has fully tiered (and run escape
    // analysis on) the curried path before we measure it — otherwise an under-warmed
    // curried form reads as a tax that a warmed JIT would have optimized away.
    warmUp(b.curry, n);
    warmUp(b.uncurry, n);
    const c = nsPerOp(b.curry, n);
    const u = nsPerOp(b.uncurry, n);
    ratios.push(c / u);
    cells.push(`${fmt(c).padStart(8)} ${fmt(u).padStart(8)} ${(`${(c / u).toFixed(2)}x`).padStart(6)}`);
  }
  console.log(`${String(n).padStart(9)}   ${cells.join("  ")}`);
  rows.push(`${n} ${ratios.map((r) => r.toFixed(4)).join(" ")}`);
}

console.log("\nc/u = curried / uncurried time. ~1.0 = currying is free; >1.0 = the backend taxes currying.");
console.log("wasm keeps curried ≡ uncurried by construction (mkFnN = identity, runFnN = saturated apply).");
console.log("In JS it depends on the codegen + JIT: V8's escape analysis frees the stock purs backend's");
console.log("curried closures (~1.0), but purs-backend-es still pays ~3x for curried application.");

const outDir = fileURLToPath(new URL("./results", import.meta.url));
mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/curry.dat`, "# input-size  wasm-ratio  naive-ratio  es-ratio\n" + rows.join("\n") + "\n");
console.log(`\nwrote ${outDir}/curry.dat`);
