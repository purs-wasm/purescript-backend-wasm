// Bin-integration regression test (ADR 0016): a PRIVATE `foreign import` (not in the
// module's export list) is absent from `externs.cbor`, so resolving it relies on the bin
// reconstructing its signature from `.purs` source — located via spago's `cache-db.json`.
// `examples/priv` has a private `secretImpl :: Int -> Int` (foreign.js: n => n * 10) used by
// an exported `triple`. We build the example with spago (which writes cache-db.json + the
// CoreFn/externs/foreign), bundle it through the CLI, and check `triple(5) === 50`. Without
// source reconstruction the bundle build fails with "unknown callee: …secretImpl".
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (msg) => {
  console.error("sourceForeign: FAIL —", msg);
  process.exit(1);
};

// compile the example (emits cache-db.json with the source path the bin reads)
const compiled = mkdtempSync(join(tmpdir(), "priv-out-"));
execFileSync("spago", ["build", "-p", "examples-priv", "--output", compiled], { cwd: repo, stdio: "inherit" });
execFileSync("spago", ["build", "-p", "bin"], { cwd: repo, stdio: "inherit" });

const bundle = mkdtempSync(join(tmpdir(), "priv-bundle-"));
execFileSync(
  "node",
  ["bin/index.dev.js", "build", "-e", "Examples.Priv.Main", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const m = await import(pathToFileURL(join(bundle, "Examples.Priv.Main", "index.mjs")).href);
if (typeof m.exports.triple !== "function")
  fail(`expected exported triple to be a function, got ${typeof m.exports.triple}`);
const got = m.exports.triple(5);
if (got !== 50)
  fail(`private foreign secretImpl did not resolve correctly: triple(5) = ${got} (expected 50)`);

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("sourceForeign: OK — private foreign resolved from source (cache-db.json); triple(5) === 50");
