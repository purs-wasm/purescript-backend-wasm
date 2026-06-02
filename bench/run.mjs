// Benchmark runner for the wasm backend. For each `Int -> Int` entry of the
// self-contained `Bench.Main` wasm, it sweeps a range of input sizes and times
// each, so the result is a time-vs-input curve per benchmark. Results are recorded
// to JSON (and, in snapshot mode, one gnuplot data file per benchmark) so
// optimization work can be measured against this baseline.
//
//   build:    npm run build
//   baseline: npm run bench       -> snapshots/baseline.json
//   snapshot: npm run snapshot    -> snapshots/<datetime>/{results.json,*.dat,*.png}
//
// Each entry returns a checksum/result, recorded per point so a before/after
// comparison can confirm the computation is unchanged. The wasm is self-contained
// (runtime merged), so it instantiates with no imports (Node 22+).

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const wasmPath = fileURLToPath(new URL("./output-wasm/Bench.Main/index.wasm", import.meta.url));
const bytes = readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const x = instance.exports;

// The baseline (set by `npm run base`), if any: a `name -> size -> ms` lookup that
// snapshots overlay and compare against.
const baselinePath = fileURLToPath(new URL("./snapshots/baseline.json", import.meta.url));
let baseline = null;
if (existsSync(baselinePath)) {
  try {
    baseline = {};
    for (const b of JSON.parse(readFileSync(baselinePath, "utf8")).benchmarks) {
      baseline[b.name] = Object.fromEntries(b.points.map((p) => [p.size, p.ms]));
    }
  } catch {
    baseline = null;
  }
}

// name, the input sizes to sweep, and what it stresses.
const benches = [
  { name: "fib", sizes: [20, 22, 24, 26, 28], desc: "tree recursion + Int arithmetic" },
  { name: "sumLoop", sizes: [200_000, 400_000, 600_000, 800_000, 1_000_000], desc: "tail loop; +/*/> via Prelude dicts" },
  { name: "qsort", sizes: [500, 1000, 1500, 2000, 3000], desc: "list quicksort: closures, Ord, alloc" },
  { name: "nqueens", sizes: [6, 7, 8, 9], desc: "backtracking; mutual recursion" },
  { name: "bintreeDfs", sizes: [12, 13, 14, 15, 16, 17], desc: "DFS over a balanced tree" },
  { name: "bintreeBfs", sizes: [8, 9, 10, 11, 12], desc: "BFS (list queue) over a tree" },
];

// Adaptive timing: warm up, calibrate the repetition count so a timed batch runs
// long enough to be stable, then take the min over several trials (ns per call).
function nsPerOp(fn, arg) {
  for (let i = 0; i < 10; i++) fn(arg); // warmup (let V8 JIT settle)
  let reps = 1;
  for (; ;) {
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

console.log(`wasm: ${bytes.length} bytes  (Bench.Main bundle)\n`);

const results = [];
for (const b of benches) {
  const fn = x[b.name];
  const points = [];
  for (const size of b.sizes) {
    const result = fn(size);
    const ns = nsPerOp(fn, size);
    points.push({ size, nsPerOp: Math.round(ns), ms: Number((ns / 1e6).toFixed(4)), result });
  }
  results.push({ name: b.name, desc: b.desc, points });
  console.log(`${b.name.padEnd(11)} ${points.map((p) => `${p.size}:${fmt(p.nsPerOp)}`).join("  ")}`);
}

const out = { wasmBytes: bytes.length, node: process.version, benchmarks: results };

// Optional snapshot directory (argv[2]): write results.json + one gnuplot data
// file per benchmark (`<name>.dat`, rows "size ms"). With no argument, write the
// tracked snapshots/baseline.json.
const argDir = process.argv[2];
if (argDir) {
  const dir = resolve(argDir);
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/results.json`, JSON.stringify(out, null, 2) + "\n");
  // each .dat: "size  baseline-ms  current-ms"  (baseline = NaN when absent, which
  // gnuplot skips), so the graph overlays the baseline curve and the current one.
  for (const b of results) {
    const base = baseline?.[b.name] ?? {};
    const dat = b.points.map((p) => `${p.size} ${base[p.size] ?? "NaN"} ${p.ms}`).join("\n") + "\n";
    writeFileSync(`${dir}/${b.name}.dat`, "# input-size  baseline-ms  current-ms\n" + dat);
  }
  console.log(`\nwrote ${dir}/results.json + ${results.length} *.dat files`);
  // speedup vs baseline at the largest input
  if (baseline) {
    console.log("\nvs baseline (largest input):");
    for (const b of results) {
      const last = b.points[b.points.length - 1];
      const base = baseline[b.name]?.[last.size];
      if (base != null) {
        console.log(`  ${b.name.padEnd(11)} ${base.toFixed(1)}ms -> ${last.ms.toFixed(1)}ms  (${(base / last.ms).toFixed(2)}x)`);
      }
    }
  }
} else {
  const dir = fileURLToPath(new URL("./snapshots", import.meta.url));
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/baseline.json`, JSON.stringify(out, null, 2) + "\n");
  console.log(`\nwrote ${dir.replace(process.cwd() + "/", "")}/baseline.json  (baseline set)`);
}
