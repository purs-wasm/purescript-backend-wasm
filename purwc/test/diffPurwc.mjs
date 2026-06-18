// Differential oracle for the `purwc` single-module worker (ADR 0038 Phase B / M1). For each
// dependency-free fixture it compiles the module TWO ways and checks they agree:
//
//   * candidate: `purwc compile` — the standalone single-module worker → <out>/<Module>.{pmi,pmo,wasm}
//   * oracle:    `purs-wasm build --per-module-codegen` — the whole-program core that ALSO emits a
//                per-module wasm (+ its .pmi/.pmo cache) to <out>/_build/<Module>.{pmi,pmo,wasm}
//
// For a dependency-free module the two are BYTE-IDENTICAL across all three artifacts — purwc reuses
// the exact same optimize (`compileModuleMir`) and codegen (`compileModuleWasm`) the oracle runs,
// just driven for one module. Byte parity is the contract here (M1); behaviour is also probed as a
// backstop (instantiate the standalone wasm, call the exported entries).
//
//   node purwc/test/diffPurwc.mjs
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));

// name → fixture package + module + behaviour probes. Each probe calls an exported i32→i32 entry.
const CORPUS = [
  {
    name: "solo",
    pkg: "purwc-fixtures",
    module: "Purwc.Fixture.Solo",
    calls: [
      { fn: "next", args: [0] },
      { fn: "next", args: [1] },
      { fn: "next", args: [2] },
      { fn: "twice", args: [0] },
      { fn: "twice", args: [2] },
    ],
  },
];

const sh = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const tmp = (tag) => mkdtempSync(join(tmpdir(), `purwcdiff-${tag}-`));

// Instantiate a standalone (import-free) module wasm and run its probes, returning a JSON outcome.
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
  process.stdout.write(`• ${c.name} (${c.module}): `);
  try {
    const corefn = tmp(`cf-${c.name}`);
    const oracleOut = tmp(`oracle-${c.name}`);
    const purwcOut = tmp(`purwc-${c.name}`);
    tmps.push(corefn, oracleOut, purwcOut);

    sh("spago", ["build", "-p", c.pkg, "--output", corefn]);
    // oracle: whole-program per-module core → _build/<Module>.{pmi,pmo,wasm}
    sh("node", ["purs-wasm/index.dev.js", "build", "--per-module-codegen", "-e", c.module, "-I", corefn, "-O", oracleOut, "--force"]);
    // candidate: the standalone worker → <out>/<Module>.{pmi,pmo,wasm}
    sh("node", ["purwc/index.dev.js", "compile", "-e", c.module, "-I", corefn, "-O", purwcOut]);

    const arts = ["pmi", "pmo", "wasm"];
    const byteResults = arts.map((ext) => {
      const a = join(oracleOut, "_build", `${c.module}.${ext}`);
      const b = join(purwcOut, `${c.module}.${ext}`);
      return { ext, eq: existsSync(a) && existsSync(b) && sha(a) === sha(b) };
    });
    const allBytesEq = byteResults.every((r) => r.eq);

    const behA = await behaviour(join(oracleOut, "_build", `${c.module}.wasm`), c.calls);
    const behB = await behaviour(join(purwcOut, `${c.module}.wasm`), c.calls);
    const behEq = behA === behB;

    const ok = allBytesEq && behEq;
    if (!ok) failures++;
    const byteTag = byteResults.map((r) => `${r.ext}:${r.eq ? "✓" : "✗"}`).join(" ");
    console.log(`bytes [${byteTag}] | behaviour ${behEq ? "match" : "MISMATCH"}${ok ? "" : "  <-- FAIL"}`);
    if (!behEq) console.log(`    oracle: ${behA}\n    purwc:  ${behB}`);
  } catch (e) {
    failures++;
    console.log(`ERROR: ${e?.message ?? e}`);
  }
}

for (const t of tmps) rmSync(t, { recursive: true, force: true });
if (failures) {
  console.error(`\n✗ ${failures} fixture(s) failed.`);
  process.exit(1);
}
console.log("\n✓ purwc matches the per-module oracle (byte + behaviour).");
