// Differential oracle for the per-module compiler (ADR 0037 Phase 2). Builds each corpus program
// two ways — the default whole-program core (`finishLink`, the oracle) and the per-module core
// (`--per-module-codegen` → `linkPerModule`; the engine moves to the standalone `purwc` at Slice
// 2.2) — and checks they agree:
//
//   * wasm bytes (sha256): while the per-module core is a stub that delegates to whole-program
//     (Slice 2.0) the two are byte-IDENTICAL; once the per-module engine diverges (Slices 2.1+)
//     bytes differ (per-module code-fn numbering, boxed cross-module boundary) and BEHAVIOUR is
//     the contract.
//   * behaviour: a set of probes — run `main` (loader-having programs) and/or call exported
//     entries with fixed args — is run against both bundles and the {stdout, result, error}
//     outcome compared. This survives byte divergence and covers loader-less / export-driven
//     programs (metatheory, effect-prim) that have no `main`.
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

// name → spago package + entry module, plus behaviour probes: `main: true` runs the loader's
// `main` (capturing stdout); `calls` invokes exported entries with fixed args (capturing the
// returned value). An exported `Effect a` is a `() => a` thunk; a pure value/function is called
// or read as-is. Probes are compared by outcome, so the same args must be deterministic.
const CORPUS = [
  { name: "helloworld", pkg: "examples-helloworld", entry: "Examples.HelloWorld.Main", main: true },
  { name: "effect-ref", pkg: "examples-effect-ref", entry: "Examples.EffRef.Main", main: true },
  {
    name: "effect-prim",
    pkg: "examples-effect-prim",
    entry: "Examples.EffPrim.Main",
    calls: ["forETest", "foreachETest", "whileETest", "untilETest", "effFnTest", "unsafeTest", "voidTest", "mapTest"].map(
      (fn) => ({ fn, args: [] }),
    ),
  },
  { name: "record-meta", pkg: "examples-recordmeta", entry: "Examples.RecordMeta", main: true },
  { name: "run", pkg: "examples-run", entry: "Examples.Run.Main", main: true },
  {
    name: "metatheory",
    pkg: "examples-metatheory",
    entry: "Examples.Metatheory.Main",
    calls: [0, 1, 2, 3].map((i) => ({ fn: "runSample", args: [i] })),
  },
];

const want = process.argv.slice(2);
const corpus = want.length ? CORPUS.filter((c) => want.includes(c.name)) : CORPUS;

const sh = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const tmp = (tag) => mkdtempSync(join(tmpdir(), `pmdiff-${tag}-`));

// Run the entry's probes (main + exported calls) through its loader, returning a JSON outcome
// (per-probe stdout / result / error). Returns null if the program has no probes. A load-time
// throw (e.g. instantiation) is itself part of the outcome, so two bundles that fail identically
// are still behaviour-equal.
async function behaviour(bundleDir, entry) {
  if (!entry.main && !(entry.calls && entry.calls.length)) return null;
  const mjs = join(bundleDir, "index.mjs");
  if (!existsSync(mjs)) return JSON.stringify({ noLoader: true });
  const outcomes = [];
  const out = [];
  const orig = console.log;
  console.log = (...a) => out.push(a.join(" "));
  try {
    const mod = await import(pathToFileURL(mjs).href);
    if (entry.main) {
      out.length = 0;
      let error = null;
      try {
        mod.exports.main();
      } catch (e) {
        error = String(e?.message ?? e);
      }
      outcomes.push({ probe: "main", stdout: out.join("\n"), error });
    }
    for (const c of entry.calls ?? []) {
      let result = null;
      let error = null;
      try {
        const fn = mod.exports[c.fn];
        result = typeof fn === "function" ? fn(...c.args) : fn;
      } catch (e) {
        error = String(e?.message ?? e);
      }
      outcomes.push({ probe: `${c.fn}(${c.args.join(",")})`, result, error });
    }
  } catch (loadErr) {
    console.log = orig;
    return JSON.stringify({ loadError: String(loadErr?.message ?? loadErr) });
  }
  console.log = orig;
  return JSON.stringify(outcomes);
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

    const behA = await behaviour(bundleA, c);
    const behB = await behaviour(bundleB, c);
    let behaviourTag;
    if (behA === null && behB === null) behaviourTag = "n/a (no probes)";
    else if (behA === behB) behaviourTag = "match";
    else {
      behaviourTag = "MISMATCH";
      console.log(`\n    oracle:\n      ${behA}\n    per-module:\n      ${behB}`);
    }

    const wasmTag = bytesEq ? "identical" : `differ (${hashA.slice(0, 8)} vs ${hashB.slice(0, 8)})`;
    const ok = behaviourTag !== "MISMATCH"; // bytes may legitimately differ; behaviour must not
    if (!ok) failures++;
    console.log(`wasm ${wasmTag} | behaviour ${behaviourTag}`);
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
