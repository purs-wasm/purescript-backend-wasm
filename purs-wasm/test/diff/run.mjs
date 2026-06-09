// Differential parity harness driver. For every case in cases.mjs, build the SAME input
// with both CLIs — the legacy `bin` oracle and the new `purs-wasm` — into two scratch
// directories, then assert the resulting artifact trees are byte-identical (index.wasm or
// index.wat, index.mjs, foreign/<M>.js). This is the parity gate that lets `purs-wasm`
// replace `bin`: as long as it holds, the rewrite is behaviour-neutral by construction.
//
// stdout is NOT compared — it carries no build artifact, only progress logging (which the
// two CLIs render differently). Only the on-disk output matters.
//
// Prerequisites (runtime.wasm, ulib/, bench/output) are produced by the `test:diff` script
// in package.json before this driver runs; here we assume the inputs exist.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, relative } from "node:path";

import { cases } from "./cases.mjs";

const repo = fileURLToPath(new URL("../../../", import.meta.url));
const BIN = "bin/index.dev.js";
const PURS_WASM = "purs-wasm/index.dev.js";

// Build one case with the given CLI entry into `out`. Returns null on success or the
// captured stderr on failure (a crash in either CLI is itself a parity failure).
function build(entry, args, out) {
  try {
    execFileSync("node", [entry, "build", ...args, "-O", out], { cwd: repo, stdio: "pipe" });
    return null;
  } catch (e) {
    return (e.stderr?.toString() || e.message || "").trim();
  }
}

// Every file under `dir` as a repo-of-`dir`-relative path → contents, so two trees can be
// compared by key set and by bytes regardless of traversal order.
function readTree(dir) {
  const files = new Map();
  const walk = (d) => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else files.set(relative(dir, p), readFileSync(p));
    }
  };
  walk(dir);
  return files;
}

// Compare two trees; return an array of human-readable difference descriptions (empty = match).
function diffTrees(aTree, bTree) {
  const diffs = [];
  const keys = new Set([...aTree.keys(), ...bTree.keys()]);
  for (const k of [...keys].sort()) {
    const a = aTree.get(k);
    const b = bTree.get(k);
    if (a === undefined) diffs.push(`only in purs-wasm: ${k}`);
    else if (b === undefined) diffs.push(`only in bin: ${k}`);
    else if (!a.equals(b)) diffs.push(`differs (${a.length} vs ${b.length} bytes): ${k}`);
  }
  return diffs;
}

let pass = 0;
const failures = [];

for (const c of cases) {
  const aOut = mkdtempSync(join(tmpdir(), "pw-diff-bin-"));
  const bOut = mkdtempSync(join(tmpdir(), "pw-diff-pw-"));
  try {
    const aErr = build(BIN, c.args, aOut);
    const bErr = build(PURS_WASM, c.args, bOut);
    if (aErr || bErr) {
      failures.push({ name: c.name, why: `build failed — bin: ${aErr ?? "ok"} | purs-wasm: ${bErr ?? "ok"}` });
      continue;
    }
    const diffs = diffTrees(readTree(aOut), readTree(bOut));
    if (diffs.length === 0) {
      pass++;
      console.log(`  ✓ ${c.name}`);
    } else {
      failures.push({ name: c.name, why: diffs.join("\n      ") });
    }
  } finally {
    rmSync(aOut, { recursive: true, force: true });
    rmSync(bOut, { recursive: true, force: true });
  }
}

console.log(`\ndiff: ${pass} passed, ${failures.length} failed (of ${cases.length})`);
if (failures.length > 0) {
  console.error("\nparity failures:");
  for (const f of failures) console.error(`  ✗ ${f.name}\n      ${f.why}`);
  process.exit(1);
}
