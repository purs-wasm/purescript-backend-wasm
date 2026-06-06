// Thorough oracle test for `$rt.showNumber` (Data.Show's showNumberImpl).
//
// We cannot eyeball the WAT, so this drives the runtime directly from JS: pass an
// f64 to `showNumber` (wasm f64 params accept JS numbers), read the rendered $Str
// back via the strLen/strByteAt bridge, and compare against the exact reference —
// JS's own `String(n)` plus the same `.0` rule the foreign uses. Covers hand-picked
// edge cases plus a large sweep of random bit patterns. Exits non-zero on mismatch.
import { readFileSync } from "node:fs";

// resolve relative to this file so it works whatever the cwd is. `showNumberImpl` now
// lives in the curated `ulib/Data.Show` module (ADR 0012); instantiate it against the
// runtime (which still provides the `$Str` read primitives) and call its export.
const runtimePath = new URL("../../runtime/runtime.wasm", import.meta.url);
const showPath = new URL("../../ulib/Data.Show/foreign.wasm", import.meta.url);
const rt = new WebAssembly.Instance(
  new WebAssembly.Module(readFileSync(runtimePath)),
  {},
).exports;
const show = new WebAssembly.Instance(
  new WebAssembly.Module(readFileSync(showPath)),
  { rt },
).exports;

// The reference: exactly what Prelude's `showNumberImpl` computes.
//   var str = n.toString(); return isNaN(str + ".0") ? str : str + ".0";
function oracle(n) {
  const str = String(n);
  return isNaN(str + ".0") ? str : str + ".0";
}

const dec = new TextDecoder();
function wasmShow(n) {
  const s = show.showNumberImpl(n);
  const len = rt.strLen(s);
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) bytes[i] = rt.strByteAt(s, i);
  return dec.decode(bytes);
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

console.log(`showNumber: ${pass} passed, ${fail} failed (of ${pass + fail})`);
if (fail > 0) {
  console.log("first failures:");
  for (const f of failures) {
    console.log(`  ${String(f.n).padEnd(26)} want ${JSON.stringify(f.want)}  got ${JSON.stringify(f.got)}`);
  }
  process.exit(1);
}
