// Thorough oracle test for the ulib `Data.Show` shadow's `showNumberImpl` (Dragon4 f64 formatter).
//
// Drives it through the REAL pipeline (ADR 0031 phase 5): builds the `E2E.ShowNumber` fixture
// (`showNum :: Number -> String = show`) with `purs-wasm build`, loads the generated `index.mjs`, and
// calls the marshalled `showNum` export — which returns a JS string directly. Compares against the
// exact reference (JS `String(n)` plus the `.0` rule the foreign uses) over hand-picked edge cases
// and a large random sweep. Exits non-zero on mismatch. (Replaces the retired global-wat path that
// instantiated `ulib/Data.Show/foreign.wasm` against a separate runtime instance.)
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const run = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: "inherit" });

run("spago", ["build", "-p", "purs-wasm"]);
run("node", ["purs-wasm/index.dev.js", "ulib", "install"]);
const compiled = mkdtempSync(join(tmpdir(), "shownum-out-"));
run("spago", ["build", "-p", "e2e-fixtures", "--output", compiled]);
const bundle = mkdtempSync(join(tmpdir(), "shownum-bundle-"));
run("node", ["purs-wasm/index.dev.js", "build", "-e", "E2E.ShowNumber", "-I", compiled, "-O", bundle]);

const m = await import(pathToFileURL(join(bundle, "index.mjs")).href);
const wasmShow = (n) => m.exports.showNum(n);

// The reference: exactly what Prelude's `showNumberImpl` computes.
//   var str = n.toString(); return isNaN(str + ".0") ? str : str + ".0";
function oracle(n) {
  const str = String(n);
  return isNaN(str + ".0") ? str : str + ".0";
}

let pass = 0;
let fail = 0;
const failures = [];
function check(n) {
  let got, want;
  try {
    want = oracle(n);
    got = wasmShow(n);
  } catch (e) {
    got = "<threw: " + e.message + ">";
    want = oracle(n);
  }
  if (got === want) pass++;
  else {
    fail++;
    if (failures.length < 40) failures.push({ n, want, got });
  }
}

// --- hand-picked edge cases ---
const edge = [
  0, -0, 1, -1, 2, 10, 100, 0.5, -0.5, 0.25, 0.1, 0.2, 0.3, 0.1 + 0.2,
  1.5, 2.5, 3.14159265358979, -3.14159265358979, 123.456, -123.456,
  1e1, 1e2, 1e5, 1e15, 1e20, 1e21, 1e22, 1e-1, 1e-5, 1e-6, 1e-7, 1e-10,
  9007199254740992, 9007199254740993, 9007199254740994, // around 2^53
  12345678901234567890, 0.000001, 0.0000001, 100000000000000000000,
  1e100, 1e300, 1e308, Number.MAX_VALUE, Number.MIN_VALUE, 5e-324,
  Math.PI, Math.E, Math.sqrt(2), 1 / 3, 2 / 3, 10 / 3,
  Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, 4294967296, 4294967295,
  Infinity, -Infinity, NaN,
];
for (const n of edge) check(n);
for (const n of edge) check(-n);

// --- random sweep over raw 64-bit patterns reinterpreted as f64 ---
const buf = new ArrayBuffer(8);
const u32 = new Uint32Array(buf);
const f64 = new Float64Array(buf);
const COUNT = 100000;
// deterministic LCG so failures are reproducible
let state = 0x12345678 >>> 0;
const rand32 = () => (state = (Math.imul(state, 1664525) + 1013904223) >>> 0);
for (let i = 0; i < COUNT; i++) {
  u32[0] = rand32();
  u32[1] = rand32();
  check(f64[0]);
}

// --- many "normal-looking" decimals (these stress shortest-digit choices) ---
for (let i = 0; i < 30000; i++) {
  const mant = rand32() / 4294967296; // [0,1)
  const exp = (rand32() % 60) - 30;
  check(mant * Math.pow(10, exp));
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });

console.log(`showNumber: ${pass} passed, ${fail} failed (of ${pass + fail})`);
if (fail > 0) {
  console.log("first failures:");
  for (const f of failures) {
    console.log(`  ${String(f.n).padEnd(26)} want ${JSON.stringify(f.want)}  got ${JSON.stringify(f.got)}`);
  }
  process.exit(1);
}
