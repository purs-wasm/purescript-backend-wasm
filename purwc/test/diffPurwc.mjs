// Differential oracle for the `purwc` single-module worker (ADR 0038 Phase B). Each fixture is
// compiled TWO ways and checked to agree:
//
//   * candidate: `purwc compile` per module (a dependent reads ONLY its dependencies' `.pmi`
//     INTERFACES — never their `.pmo`/object code), then the per-module `.wasm`s are `wasm-merge`d.
//   * oracle:    `purs-wasm build --per-module-codegen` — the whole-program core that emits the same
//     per-module `.wasm` (+ `.pmi`) to `_build/` and the merged `index.wasm`.
//
// Contracts:
//   * every module's `.pmi` is BYTE-identical to the oracle's `_build/<M>.pmi` — the optimize
//     (`compileModuleMir`) and the derived interface (`moduleInterface`) are deterministic and
//     dependent-independent, so a module's interface does not depend on HOW it is built;
//   * the merged program is BEHAVIOUR-identical to the whole-program oracle — but a per-module
//     `.wasm` legitimately diverges in bytes (the worker over-exports all its functions, since it
//     cannot see its dependents, pinning more to the boxed ABI than the whole-program oracle;
//     behaviour-safe, ADR 0037);
//   * `purwc` writes NO `.pmo` (retired — the `.pmi` is the complete interface, the `.wasm` the
//     object).
//
//   node purwc/test/diffPurwc.mjs
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const wasmMerge = join(repo, "binaryen", "node_modules", "binaryen", "bin", "wasm-merge");

// (only a single dependency-free module), and i32→i32 behaviour probes on the entry's exports.
const CORPUS = [
  {
    name: "solo (leaf)",
    pkg: "purwc-fixtures",
    entry: "Purwc.Fixture.Solo",
    modules: ["Purwc.Fixture.Solo"],
    calls: [{ fn: "next", args: [0] }, { fn: "twice", args: [0] }, { fn: "twice", args: [2] }],
  },
  {
    name: "user→dep (cross-module)",
    pkg: "purwc-fixtures",
    entry: "Purwc.Fixture.User",
    modules: ["Purwc.Fixture.Dep", "Purwc.Fixture.User"],
    calls: [{ fn: "twice", args: [0] }, { fn: "twice", args: [1] }, { fn: "twice", args: [2] }],
  },
  {
    // transitive dep (Top→Mid→Base) + cross-module constructor construct/match (Box)
    name: "top→mid→base (transitive + cross-module ctor)",
    pkg: "purwc-fixtures",
    entry: "Purwc.Fixture.Top",
    modules: ["Purwc.Fixture.Base", "Purwc.Fixture.Mid", "Purwc.Fixture.Top"],
    calls: [
      { fn: "rotate4", args: [0] }, { fn: "rotate4", args: [1] }, { fn: "rotate4", args: [2] },
      { fn: "viaBox", args: [0] }, { fn: "viaBox", args: [1] }, { fn: "viaBox", args: [2] },
    ],
  },
  {
    // a dependent calling a foreign declared in ANOTHER module — resolved via the dep `.pmi`'s
    // foreignSigs (a foreign has no MIR binding, so it is absent from `funcs`).
    name: "foreign re-export (cross-module foreign call)",
    pkg: "purwc-fixtures",
    entry: "Purwc.Fixture.ForeignUser",
    modules: ["Purwc.Fixture.ForeignDep", "Purwc.Fixture.ForeignUser"],
    imports: { "Purwc.Fixture.ForeignDep": { bumpInt: (x) => x + 1 } },
    calls: [{ fn: "useBump", args: [0] }, { fn: "useBump", args: [5] }],
  },
];

const sh = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const tmp = (tag) => mkdtempSync(join(tmpdir(), `purwcdiff-${tag}-`));

// Instantiate a wasm (with any `imports` it needs — e.g. a JS foreign) and run its i32 probes.
async function behaviour(wasmPath, calls, imports = {}) {
  if (!existsSync(wasmPath)) return JSON.stringify({ missing: wasmPath });
  let ex;
  try {
    const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), imports);
    ex = instance.exports;
  } catch (e) {
    return JSON.stringify({ loadError: String(e?.message ?? e) });
  }
  return JSON.stringify(
    calls.map((c) => {
      try {
        const fn = ex[c.fn];
        const result = typeof fn === "function" ? fn(...c.args) : fn;
        return { probe: `${c.fn}(${c.args.join(",")})`, result, error: null };
      } catch (e) {
        return { probe: `${c.fn}(${c.args.join(",")})`, result: null, error: String(e?.message ?? e) };
      }
    }),
  );
}

console.log("Building purs-wasm + purwc…");
sh("spago", ["build", "-p", "purs-wasm"]);
sh("spago", ["build", "-p", "purwc"]);

let failures = 0;
const tmps = [];
for (const c of CORPUS) {
  process.stdout.write(`• ${c.name}: `);
  try {
    const corefn = tmp(`cf`);
    const oracleOut = tmp(`oracle`);
    const purwcOut = tmp(`purwc`);
    const orchOut = tmp(`orch`);
    tmps.push(corefn, oracleOut, purwcOut, orchOut);

    sh("spago", ["build", "-p", c.pkg, "--output", corefn]);
    // oracle: whole-program per-module core → _build/<M>.{pmi,wasm} + merged index.wasm
    sh("node", ["purs-wasm/index.dev.js", "build", "--per-module-codegen", "-e", c.entry, "-I", corefn, "-O", oracleOut, "--force"]);
    // candidate A: compile each module in dep order; a dependent reads earlier modules' .pmi (--deps).
    // Only the entry is compiled with --entry (host-ABI bare exports); libraries export keys only.
    for (const m of c.modules) {
      sh("node", ["purwc/index.dev.js", "compile", "-e", m, "-I", corefn, "--deps", purwcOut, "-O", purwcOut, ...(m === c.entry ? ["--entry"] : [])]);
    }
    // ensure the worker wrote NO .pmo
    const wrotePmo = c.modules.some((m) => existsSync(join(purwcOut, `${m}.pmo`)));
    // merge the per-module wasms (by dotted module name, matching the cross-module import fields)
    const mergeArgs = c.modules.flatMap((m) => [join(purwcOut, `${m}.wasm`), m]);
    sh(wasmMerge, [...mergeArgs, "-o", join(purwcOut, "merged.wasm"), "--all-features"]);
    // candidate B: the real Phase-C orchestrator (purs-wasm spawns purwc per module + links)
    sh("node", ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", c.entry, "-I", corefn, "-O", orchOut, "--force"]);

    // every module's `.pmi` must byte-match the oracle's (interface is dependent-independent);
    // the per-module `.wasm` byte match is reported but NOT required (over-export divergence).
    const pmiEq = c.modules.every((m) => sha(join(purwcOut, `${m}.pmi`)) === sha(join(oracleOut, "_build", `${m}.pmi`)));
    const wasmEq = c.modules.every((m) => sha(join(purwcOut, `${m}.wasm`)) === sha(join(oracleOut, "_build", `${m}.wasm`)));

    const imports = c.imports ?? {};
    const behA = await behaviour(join(oracleOut, "index.wasm"), c.calls, imports);
    const behB = await behaviour(join(purwcOut, "merged.wasm"), c.calls, imports);
    const behC = await behaviour(join(orchOut, "index.wasm"), c.calls, imports);
    const behEq = behA === behB && behA === behC;

    if (!pmiEq || !behEq || wrotePmo) failures++;
    const pmoTag = wrotePmo ? " | .pmo:WROTE(should not!)" : "";
    console.log(`pmi ${pmiEq ? "✓ byte-identical" : "✗ DIFFER"} | wasm ${wasmEq ? "byte-identical" : "diverges (over-export, ok)"} | manual-merge+orchestrate behaviour ${behEq ? "match" : "MISMATCH"}${pmoTag}`);
    if (!behEq) console.log(`    oracle:      ${behA}\n    manualMerge: ${behB}\n    orchestrate: ${behC}`);
  } catch (e) {
    failures++;
    console.log(`ERROR: ${e?.message ?? e}`);
  }
}

// ── ulib regression (ADR 0038 Phase C2): a real Prelude + foreign program with lib shadows. The
// orchestrator stages the lib-shadowed corefn, treats only the entry as a host-ABI root, and feeds
// the optimizer the dependencies' effectful foreigns. Run `main` through each loader, compare stdout.
async function mainStdout(bundleDir) {
  const mjs = join(bundleDir, "index.mjs");
  if (!existsSync(mjs)) return JSON.stringify({ noLoader: true });
  const out = [];
  const orig = console.log;
  console.log = (...a) => out.push(a.join(" "));
  try {
    const mod = await import(`${pathToFileURL(mjs).href}?t=${bundleDir}`);
    mod.exports.main();
  } catch (e) {
    console.log = orig;
    return JSON.stringify({ error: String(e?.message ?? e) });
  }
  console.log = orig;
  return JSON.stringify(out);
}

process.stdout.write("• ulib: examples-helloworld (Prelude + foreign + lib shadows): ");
try {
  const cf = tmp("ulibcf"), ora = tmp("ulibora"), orc = tmp("uliborc");
  tmps.push(cf, ora, orc);
  sh("spago", ["build", "-p", "examples-helloworld", "--output", cf]);
  sh("node", ["purs-wasm/index.dev.js", "build", "-e", "Examples.HelloWorld.Main", "-I", cf, "-O", ora, "--force"]);
  sh("node", ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", "Examples.HelloWorld.Main", "-I", cf, "-O", orc]);
  const sA = await mainStdout(ora);
  const sB = await mainStdout(orc);
  const ok = sA === sB && sB.includes("Hello from WASM World") && !sB.includes("should not be printed");
  if (!ok) failures++;
  console.log(`main() stdout ${sA === sB ? "match" : "MISMATCH"}${ok ? "" : "  <-- FAIL"}`);
  if (sA !== sB) console.log(`    oracle: ${sA}\n    orchestrate: ${sB}`);
} catch (e) {
  failures++;
  console.log(`ERROR: ${e?.message ?? e}`);
}

// ── ADR 0039 wat-only patch regression (blocker ②): a program reaching `Data.Int` (a wat-only
// patch — registry corefn kept, foreign from the lib). Under `--orchestrate` the worker over-exports
// `Data.Int.fromNumber` → `Data.Number.isFinite`; the abolished "foreign-only" half-shadow used to
// drop `Data.Number` from the staged set and fail with `unknown callee`. Build oracle + orchestrate,
// compare `main()` stdout (both must print the same `Data.Int.fromString "42"` result).
process.stdout.write("• ulib: examples-intpatch (wat-only Data.Int → Data.Number reach): ");
try {
  const cf = tmp("intcf"), ora = tmp("intora"), orc = tmp("intorc");
  tmps.push(cf, ora, orc);
  sh("spago", ["build", "-p", "examples-intpatch", "--output", cf]);
  sh("node", ["purs-wasm/index.dev.js", "build", "-e", "Examples.IntPatch.Main", "-I", cf, "-O", ora, "--force"]);
  sh("node", ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", "Examples.IntPatch.Main", "-I", cf, "-O", orc]);
  const sA = await mainStdout(ora);
  const sB = await mainStdout(orc);
  const ok = sA === sB && sB.includes("(Just 42)");
  if (!ok) failures++;
  console.log(`main() stdout ${sA === sB ? "match" : "MISMATCH"}${ok ? "" : "  <-- FAIL"}`);
  if (sA !== sB) console.log(`    oracle: ${sA}\n    orchestrate: ${sB}`);
} catch (e) {
  failures++;
  console.log(`ERROR: ${e?.message ?? e}`);
}

// ── #19 dead-CAF reachability regression: examples-run (purescript-run / Free monad) transitively
// IMPORTS Effect.Aff / Control.Monad.ST.Internal etc. but never USES them. The worker over-exports,
// so those modules' CAFs survived per-module; `caf_init` eagerly ran them and an opaque foreign that
// cannot marshal back across the JS boundary trapped at runtime ("type incompatibility from/to JS").
// The orchestrator now prunes `caf_init$M` to entry-reachable modules. Build oracle (whole-program)
// + orchestrate, run main() through each loader, require identical stdout (and that it actually ran).
process.stdout.write("• #19: examples-run (dead opaque-foreign CAF reachability under orchestrate): ");
try {
  const cf = tmp("runcf"), ora = tmp("runora"), orc = tmp("runorc");
  tmps.push(cf, ora, orc);
  sh("spago", ["build", "-p", "examples-run", "--output", cf]);
  sh("node", ["purs-wasm/index.dev.js", "build", "-e", "Examples.Run.Main", "-I", cf, "-O", ora, "--force"]);
  sh("node", ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", "Examples.Run.Main", "-I", cf, "-O", orc]);
  const sA = await mainStdout(ora);
  const sB = await mainStdout(orc);
  const ok = sA === sB && sB.includes("famished");
  if (!ok) failures++;
  console.log(`main() stdout ${sA === sB ? "match" : "MISMATCH"}${ok ? "" : "  <-- FAIL"}`);
  if (sA !== sB) console.log(`    oracle: ${sA}\n    orchestrate: ${sB}`);
} catch (e) {
  failures++;
  console.log(`ERROR: ${e?.message ?? e}`);
}

// ── ADR 0040 P3 content-addressed store, partitioned write-back: with $PURS_WASM_STORE set, the
// orchestrate build writes only LIBRARY modules (.spago dependencies + ulib shadows) to the store
// keyed by content; the project's OWN modules stay in the local _build. A second build into a fresh
// output reuses every library module from the store (only the own modules recompile) and is
// byte/behaviour-correct. The store key is computed from sources alone (sound, content-addressed).
process.stdout.write("• P3: content-addressed store, own/library write-back partition (examples-intpatch): ");
try {
  const cf = tmp("stcf"), orc1 = tmp("storc1"), orc2 = tmp("storc2"), store = tmp("ststore");
  tmps.push(cf, orc1, orc2, store);
  sh("spago", ["build", "-p", "examples-intpatch", "--output", cf]);
  const build = (out) => execFileSync("node",
    ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", "Examples.IntPatch.Main", "-I", cf, "-O", out, "--force"],
    { cwd: repo, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, PURS_WASM_STORE: store } }).toString();
  build(orc1);
  const ran1 = (await mainStdout(orc1)).includes("(Just 42)");
  const pmis = readdirSync(store).filter((f) => f.endsWith(".pmi"));
  // `_build` is OWN-ONLY (ADR 0040): a LIBRARY module's artifacts live in the store, NOT in `_build`;
  // the OWN entry lives in `_build`, NOT in the store. (The store is content-/hash-named, so a library
  // module is verified by its ABSENCE from `_build` + the store holding the library closure; the own
  // module's `_build` content is checked to NOT match any store entry.)
  const ownPmiInBuild = existsSync(join(orc1, "_build", "Examples.IntPatch.Main.pmi"));
  const libPmiInBuild = existsSync(join(orc1, "_build", "Data.Maybe.pmi"));
  const buildOwnOnly = ownPmiInBuild && !libPmiInBuild;
  const ownInStore = pmis.some((f) => sha(join(store, f)) === sha(join(orc1, "_build", "Examples.IntPatch.Main.pmi")));
  // build 2: fresh output, same store → library modules hit, own modules recompile
  const log2 = build(orc2);
  const hit = / \((\d+) from store\)/.exec(log2);
  const compiled2 = /Compiling (\d+) module/.exec(log2)?.[1];
  const ran2 = (await mainStdout(orc2)).includes("(Just 42)");
  const merged = sha(join(orc1, "index.wasm")) === sha(join(orc2, "index.wasm"));
  const after = readdirSync(store).filter((f) => f.endsWith(".pmi")).length;
  const ok = ran1 && ran2 && pmis.length > 0 && buildOwnOnly && !ownInStore && pmis.length === after
    && hit && Number(hit[1]) > 0 && Number(compiled2) >= 1 && merged;
  if (!ok) failures++;
  console.log(`${ok ? "✓" : "✗"} store ${pmis.length} lib pmi | _build own-only (own in:${ownPmiInBuild ? "yes" : "NO"}, lib in:${libPmiInBuild ? "YES(bad)" : "no"}) | own in store:${ownInStore ? "YES(bad)" : "no"} | build2: ${compiled2} compiled (own), ${hit ? hit[1] : 0} from store | index.wasm match ${merged ? "yes" : "no"} | runs ${ran1 && ran2 ? "yes" : "NO"}`);
} catch (e) {
  failures++;
  console.log(`ERROR: ${e?.message ?? e}`);
}

// ── ADR 0040 P4 prewarm: `purs-wasm prewarm -I <closure>` precompiles a package set's library closure
// (.spago + ulib shadows) into the store (resolving shadows from the lib, exactly as a build would). A
// subsequent project build then hits the store for the library and compiles only its own modules. No
// manifest is written — reuse is content-addressed.
process.stdout.write("• P4: prewarm precompiles library closure → build hits it (examples-intpatch): ");
try {
  const cf = tmp("pwcf"), orc = tmp("pworc"), store = tmp("pwstore");
  tmps.push(cf, orc, store);
  sh("spago", ["build", "-p", "examples-intpatch", "--output", cf]);
  const env = { ...process.env, PURS_WASM_STORE: store };
  execFileSync("node", ["purs-wasm/index.dev.js", "prewarm", "-I", cf], { cwd: repo, stdio: ["ignore", "pipe", "pipe"], env });
  const prewarmed = readdirSync(store).filter((f) => f.endsWith(".pmi")).length;
  const noManifest = !existsSync(join(store, "manifest.json"));
  const log = execFileSync("node",
    ["purs-wasm/index.dev.js", "build", "--orchestrate", "-e", "Examples.IntPatch.Main", "-I", cf, "-O", orc, "--force"],
    { cwd: repo, stdio: ["ignore", "pipe", "pipe"], env }).toString();
  const hit = / \((\d+) from store\)/.exec(log);
  const compiled = /Compiling (\d+) module/.exec(log)?.[1];
  const ran = (await mainStdout(orc)).includes("(Just 42)");
  const ok = prewarmed > 0 && hit && Number(hit[1]) > 0 && Number(compiled) >= 1 && ran && noManifest;
  if (!ok) failures++;
  console.log(`${ok ? "✓" : "✗"} prewarmed ${prewarmed} library | no manifest ${noManifest ? "yes" : "NO"} | build: ${compiled} compiled (own), ${hit ? hit[1] : 0} from store | runs ${ran ? "yes" : "NO"}`);
} catch (e) {
  failures++;
  console.log(`ERROR: ${e?.message ?? e}`);
}

for (const t of tmps) rmSync(t, { recursive: true, force: true });
if (failures) {
  console.error(`\n✗ ${failures} check(s) failed.`);
  process.exit(1);
}
console.log("\n✓ purwc matches the per-module oracle (byte where applicable + behaviour), no .pmo.");
