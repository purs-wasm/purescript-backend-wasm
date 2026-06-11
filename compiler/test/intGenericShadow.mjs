// CLI-integration regression test (wat-only ulib modules, ADR 0031 phase 4b-2): `Data.Int`
// (fromStringAsImpl) and `Data.Show.Generic` (intercalate) are NOT shadowed — the build uses their
// registry corefn — but ulib provides their foreign from the lib `foreign.wasm` (assembled from a
// co-located `.wat` with no sibling `.purs`). So a program using them stays STANDALONE: this builds
// `Examples.HelloWorld.IntGenericCheck` and instantiates it with NO imports (`{}`), which would fail
// if those foreigns had fallen back to JS. `check n :: Int -> Int` returns 7 iff all three pass.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("intGenericShadow: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
execFileSync("node", ["purs-wasm/index.dev.js", "ulib", "install"], { cwd: repo, stdio: "inherit" });

const compiled = mkdtempSync(join(tmpdir(), "intgen-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "intgen-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.dev.js", "build", "-e", "Examples.HelloWorld.IntGenericCheck", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const bytes = readFileSync(join(bundle, "index.wasm"));
// instantiate with NO imports: if Data.Int / Data.Show.Generic foreigns had gone to JS, this throws.
const inst = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
if (typeof inst.exports.check !== "function") fail("export `check` is not a function");

const NAMES = ["Data.Int.fromString(ok)", "Data.Int.fromString(fail)", "Data.Show.Generic.genericShow"];
const r = inst.exports.check(0);
if (r !== 7) {
  const fails = NAMES.filter((_, i) => !(r & (1 << i)));
  fail(`check(0) = ${r} (expected 7); failing: ${fails.join(", ") || "none?"}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("intGenericShadow: OK — Data.Int / Data.Show.Generic foreigns resolve from the lib (standalone, no JS)");
