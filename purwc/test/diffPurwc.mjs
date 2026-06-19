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
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
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
];

const sh = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const tmp = (tag) => mkdtempSync(join(tmpdir(), `purwcdiff-${tag}-`));

// Instantiate a standalone (import-free) wasm and run its i32 probes, as a JSON outcome.
async function behaviour(wasmPath, calls) {
  if (!existsSync(wasmPath)) return JSON.stringify({ missing: wasmPath });
  let ex;
  try {
    const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
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
    tmps.push(corefn, oracleOut, purwcOut);

    sh("spago", ["build", "-p", c.pkg, "--output", corefn]);
    // oracle: whole-program per-module core → _build/<M>.{pmi,wasm} + merged index.wasm
    sh("node", ["purs-wasm/index.dev.js", "build", "--per-module-codegen", "-e", c.entry, "-I", corefn, "-O", oracleOut, "--force"]);
    // candidate: compile each module in dep order; a dependent reads earlier modules' .pmi (--deps)
    for (const m of c.modules) {
      sh("node", ["purwc/index.dev.js", "compile", "-e", m, "-I", corefn, "--deps", purwcOut, "-O", purwcOut]);
    }
    // ensure the worker wrote NO .pmo
    const wrotePmo = c.modules.some((m) => existsSync(join(purwcOut, `${m}.pmo`)));
    // merge the per-module wasms (by dotted module name, matching the cross-module import fields)
    const mergeArgs = c.modules.flatMap((m) => [join(purwcOut, `${m}.wasm`), m]);
    sh(wasmMerge, [...mergeArgs, "-o", join(purwcOut, "merged.wasm"), "--all-features"]);

    // every module's `.pmi` must byte-match the oracle's (interface is dependent-independent);
    // the per-module `.wasm` byte match is reported but NOT required (over-export divergence).
    const pmiEq = c.modules.every((m) => sha(join(purwcOut, `${m}.pmi`)) === sha(join(oracleOut, "_build", `${m}.pmi`)));
    const wasmEq = c.modules.every((m) => sha(join(purwcOut, `${m}.wasm`)) === sha(join(oracleOut, "_build", `${m}.wasm`)));

    const behA = await behaviour(join(oracleOut, "index.wasm"), c.calls);
    const behB = await behaviour(join(purwcOut, "merged.wasm"), c.calls);
    const behEq = behA === behB;

    if (!pmiEq || !behEq || wrotePmo) failures++;
    const pmoTag = wrotePmo ? " | .pmo:WROTE(should not!)" : "";
    console.log(`pmi ${pmiEq ? "✓ byte-identical" : "✗ DIFFER"} | wasm ${wasmEq ? "byte-identical" : "diverges (over-export, ok)"} | behaviour ${behEq ? "match" : "MISMATCH"}${pmoTag}`);
    if (!behEq) console.log(`    oracle: ${behA}\n    purwc:  ${behB}`);
  } catch (e) {
    failures++;
    console.log(`ERROR: ${e?.message ?? e}`);
  }
}

for (const t of tmps) rmSync(t, { recursive: true, force: true });
if (failures) {
  console.error(`\n✗ ${failures} check(s) failed.`);
  process.exit(1);
}
console.log("\n✓ purwc matches the per-module oracle (byte where applicable + behaviour), no .pmo.");
