// Bin-integration regression test (ADR 0017): the native `Effect.Ref` cell ops
// (`new`/`write`/`modify`/`read`) are wasm-native (a `$Ref` struct + runtime helpers),
// so a `Ref` program builds with NO host import for `Effect.Ref` and runs entirely in
// wasm. `Examples.EffRef.Core.compute` threads a Ref through `new 10 → write 5 → modify
// (*3) → read` and returns `x + y = 15 + 15 = 30`. We build it via spago + the CLI and
// assert the exported `Effect Int` thunk returns 30.
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (msg) => {
  console.error("refNative: FAIL —", msg);
  process.exit(1);
};

const compiled = mkdtempSync(join(tmpdir(), "refcore-out-"));
execFileSync("spago", ["build", "-p", "examples-effect-ref", "--output", compiled], { cwd: repo, stdio: "inherit" });
execFileSync("spago", ["build", "-p", "bin"], { cwd: repo, stdio: "inherit" });

const bundle = mkdtempSync(join(tmpdir(), "refcore-bundle-"));
execFileSync(
  "node",
  ["bin/index.dev.js", "build", "-e", "Examples.EffRef.Core", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const m = await import(pathToFileURL(join(bundle, "Examples.EffRef.Core", "index.mjs")).href);
if (typeof m.exports.compute !== "function")
  fail(`expected exported compute to be an Effect thunk (function), got ${typeof m.exports.compute}`);
const got = m.exports.compute();
if (got !== 30)
  fail(`native Ref ops gave the wrong result: compute() = ${got} (expected 30)`);

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("refNative: OK — native Effect.Ref (new/write/modify/read) runs in wasm; compute() === 30");
