// Coverage test for the `effect` package's control-flow / FFI primitives: `forE`,
// `foreachE`, `whileE`, `untilE`, `Effect.Uncurried` (`mkEffectFn`/`runEffectFn`), and
// `Effect.Unsafe.unsafePerformEffect`. Each `Examples.EffPrim.Main` export computes a
// checkable result (loop bodies accumulate through the native `Effect.Ref`, ADR 0017).
// We build the module via spago + the CLI and assert every expected value, reporting
// per-function pass/fail so the gap is explicit.
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));

// name → [expected, isEffect] (Effect exports are () => a thunks; unsafeTest is a value)
const CASES = [
  ["forETest", 10, true],
  ["foreachETest", 60, true],
  ["whileETest", 5, true],
  ["untilETest", 3, true],
  ["effFnTest", 7, true],
  ["unsafeTest", 42, false],
  ["voidTest", 5, true], // void must not drop the wrapped effect (ADR 0019)
  ["mapTest", 10, true], // map/<#> over an effect must run the effect (ADR 0019)
];

const compiled = mkdtempSync(join(tmpdir(), "effprim-out-"));
execFileSync("spago", ["build", "-p", "examples-effect-prim", "--output", compiled], { cwd: repo, stdio: "inherit" });
execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "effprim-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.dev.js", "build", "-e", "Examples.EffPrim.Main", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const m = await import(pathToFileURL(join(bundle, "Examples.EffPrim.Main", "index.mjs")).href);

let failures = 0;
for (const [name, expected, isEffect] of CASES) {
  let got, err;
  try {
    const e = m.exports[name];
    got = isEffect ? e() : e;
  } catch (e) {
    err = String(e).split("\n")[0];
  }
  const ok = err === undefined && got === expected;
  if (!ok) failures++;
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}  expected ${expected}, ${err ? `threw ${err}` : `got ${got}`}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
if (failures > 0) {
  console.error(`effectPrim: ${failures}/${CASES.length} effect-primitive(s) not yet working`);
  process.exit(1);
}
console.log("effectPrim: OK — all effect-package primitives work");
