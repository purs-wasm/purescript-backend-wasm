// Differential oracle for the per-module compiler (ADR 0037 Phase 2). Builds each corpus program
// two ways — the default whole-program core (`finishLink`, the oracle) and the per-module core
// (`--per-module-codegen` → `linkPerModule`; the engine moves to the standalone `purwc` at Slice
// 2.2) — and checks they agree:
//
//   * wasm bytes (sha256): while the per-module core is a stub that delegates to whole-program
//     (Slice 2.0) the two are byte-IDENTICAL; once the per-module engine diverges (Slices 2.1+)
//     bytes differ and behaviour becomes the contract.
//   * behaviour: for a program with a runnable `main`, run both loaders and compare stdout.
//
// This is the behaviour-neutral gate for retiring the whole-program path. Run all, or a subset:
//   node compiler/test/diffPerModule.mjs               # whole corpus
//   node compiler/test/diffPerModule.mjs helloworld run
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));

// name → spago package + entry module. `hasMain` programs are also behaviour-compared (their
// `main` is run through the emitted loader and stdout captured, as examplesRun.mjs does).
const CORPUS = [
  { name: "helloworld", pkg: "examples-helloworld", entry: "Examples.HelloWorld.Main", hasMain: true },
  { name: "effect-ref", pkg: "examples-effect-ref", entry: "Examples.EffRef.Main", hasMain: true },
  { name: "effect-prim", pkg: "examples-effect-prim", entry: "Examples.EffPrim.Main", hasMain: true },
  { name: "record-meta", pkg: "examples-recordmeta", entry: "Examples.RecordMeta", hasMain: true },
  { name: "run", pkg: "examples-run", entry: "Examples.Run.Main", hasMain: true },
  { name: "metatheory", pkg: "examples-metatheory", entry: "Examples.Metatheory.Main", hasMain: true },
];

const want = process.argv.slice(2);
const corpus = want.length ? CORPUS.filter((c) => want.includes(c.name)) : CORPUS;

const sh = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const tmp = (tag) => mkdtempSync(join(tmpdir(), `pmdiff-${tag}-`));

// Run the bundle's `main` through its loader, capturing console output AND any error, so the
// *outcome* (stdout + thrown message) is what gets compared — two bundles that throw the same
// error are still behaviour-equal. Returns null if no loader/`main` (nothing to compare).
async function runMain(bundleDir) {
  const mjs = join(bundleDir, "index.mjs");
  if (!existsSync(mjs)) return null;
  const out = [];
  const orig = console.log;
  console.log = (...a) => out.push(a.join(" "));
  let error = null;
  try {
    const m = await import(pathToFileURL(mjs).href);
    if (typeof m.exports?.main !== "function") {
      console.log = orig;
      return null;
    }
    m.exports.main();
  } catch (e) {
    error = String(e?.message ?? e);
  } finally {
    console.log = orig;
  }
  return JSON.stringify({ out: out.join("\n"), error });
}

console.log("Building purs-wasm…");
sh("spago", ["build", "-p", "purs-wasm"]);

let failures = 0;
const tmps = [];
for (const c of corpus) {
  process.stdout.write(`• ${c.name}: `);
  try {
    const corefn = tmp(`cf-${c.name}`);
    tmps.push(corefn);
    sh("spago", ["build", "-p", c.pkg, "--output", corefn]);

    const bundleA = tmp(`oracle-${c.name}`);
    const bundleB = tmp(`permod-${c.name}`);
    tmps.push(bundleA, bundleB);
    const baseArgs = (out) => ["purs-wasm/index.dev.js", "build", "-e", c.entry, "-I", corefn, "-O", out, "--force"];
    sh("node", baseArgs(bundleA)); // oracle: whole-program core
    sh("node", [...baseArgs(bundleB), "--per-module-codegen"]); // candidate: per-module core

    const hashA = sha(join(bundleA, "index.wasm"));
    const hashB = sha(join(bundleB, "index.wasm"));
    const bytesEq = hashA === hashB;

    let behaviour = "n/a";
    if (c.hasMain) {
      const outA = await runMain(bundleA);
      const outB = await runMain(bundleB);
      if (outA === null && outB === null) behaviour = "n/a (no loader/main)";
      else if (outA === outB) behaviour = "match";
      else {
        behaviour = "MISMATCH";
        console.log(`\n    oracle stdout:\n${outA}\n    purwc stdout:\n${outB}`);
      }
    }

    const wasmTag = bytesEq ? "identical" : `DIFFER (${hashA.slice(0, 8)} vs ${hashB.slice(0, 8)})`;
    const ok = behaviour !== "MISMATCH"; // bytes may legitimately differ; behaviour must not
    if (!ok) failures++;
    console.log(`wasm ${wasmTag} | behaviour ${behaviour}`);
  } catch (e) {
    failures++;
    console.log(`ERROR\n    ${String(e.stderr ?? e.message ?? e).split("\n").join("\n    ")}`);
  }
}

for (const d of tmps) rmSync(d, { recursive: true, force: true });

if (failures) {
  console.error(`\ndiffPerModule: ${failures} corpus entr${failures === 1 ? "y" : "ies"} FAILED (behaviour mismatch / error)`);
  process.exit(1);
}
console.log("\ndiffPerModule: OK — the per-module core matches the whole-program core across the corpus");
