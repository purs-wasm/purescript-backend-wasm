// CLI-integration regression test (ADR 0015): an `Effect`-typed export (`main :: Effect
// Unit`) must be exposed by the generated loader as a callable THUNK `() => a` — it runs
// when CALLED, not at import time. (The bug: nullary exports were eager-evaluated at load,
// so importing the module fired `main`.) Builds the `EffMain` fixture through the CLI, then
// checks: import is silent, `exports.main` is a function, and calling it runs the effect
// once. The fixture's foreign `emit` records calls on `globalThis` so this process can
// observe them (the loader and this test share the one module instance of `foreign.js`).
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (msg) => {
  console.error("effectMain: FAIL —", msg);
  process.exit(1);
};

// ensure the CLI (output/PursWasm.CLI.Main) is current, then build the fixture bundle
execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
const out = mkdtempSync(join(tmpdir(), "effmain-"));
execFileSync(
  "node",
  ["purs-wasm/index.dev.js", "build", "-e", "EffMain", "-I", "compiler/test/fixtures/bin-effmain", "-O", out],
  { cwd: repo, stdio: "inherit" },
);

globalThis.__effmain = [];
const m = await import(pathToFileURL(join(out, "index.mjs")).href);

if (globalThis.__effmain.length !== 0)
  fail(`main ran on import (calls=${JSON.stringify(globalThis.__effmain)}); an Effect export must not run until called`);
if (typeof m.exports.main !== "function")
  fail(`Effect export must be a callable thunk, got ${typeof m.exports.main}`);
m.exports.main();
if (JSON.stringify(globalThis.__effmain) !== "[1]")
  fail(`main() must run the effect exactly once (expected [1], got ${JSON.stringify(globalThis.__effmain)})`);

rmSync(out, { recursive: true, force: true });
console.log("effectMain: OK — import is silent; exports.main() ran the effect once");
