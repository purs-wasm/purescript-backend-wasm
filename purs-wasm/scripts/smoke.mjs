// Post-prepack smoke test: pack the ASSEMBLED package and install it into a throwaway project (which
// has no monorepo `output/`, so `index.js` auto-detects the PUBLISHED path — the `bundle/` CLI + the
// shipped `purwc/` worker + the shipped `lib/`), then run a real `build`. This proves the published
// CLI's DEFAULT build (orchestrate, ADR 0042 — it spawns the `purwc` subprocess and resolves `lib/`)
// works end to end. It catches the class of breakage the unit `test` cannot see: a runtime asset
// (purwc / lib / runtime) not shipped — e.g. the published default build failing with
// "Cannot find module …/purwc/index.js". Run AFTER `npm run prepack`, from the `purs-wasm/` dir.
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { mkdtempSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const pkg = dirname(dirname(fileURLToPath(import.meta.url))); // purs-wasm/
const repo = dirname(pkg); // repo root
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: "inherit", ...opts });
const fail = (m) => {
  console.error("smoke: FAIL —", m);
  process.exit(1);
};

// A tiny example's corefn = the build input (its Prelude/etc. deps resolve from the shipped lib/).
const cf = mkdtempSync(join(tmpdir(), "smoke-cf-"));
run("spago", ["build", "-p", "examples-helloworld", "--output", cf], { cwd: repo });

// Pack the assembled package (`.npmrc` `ignore-scripts` means pack does NOT re-run prepack — it uses
// the bundle/ + purwc/ + runtime/ + lib/ that `npm run prepack` just assembled on disk).
const tgz = execFileSync("npm", ["pack"], { cwd: pkg, encoding: "utf8" })
  .trim().split("\n").filter(Boolean).pop();

// Install into a throwaway project OUTSIDE the repo tree (no `output/` ⇒ index.js takes the published
// bundle + purwc path, exactly as an `npm i purs-wasm` user would get).
const proj = mkdtempSync(join(tmpdir(), "smoke-proj-"));
writeFileSync(join(proj, "package.json"), '{ "name": "smoke", "private": true }\n');
run("npm", ["install", join(pkg, tgz)], { cwd: proj });
rmSync(join(pkg, tgz), { force: true });

// Run the DEFAULT (orchestrate) build via the installed CLI.
const out = mkdtempSync(join(tmpdir(), "smoke-out-"));
const cli = join(proj, "node_modules", "purs-wasm", "index.js");
run("node", [cli, "build", "-e", "Examples.HelloWorld.Main", "-I", cf, "-O", out], { cwd: proj });

if (!existsSync(join(out, "index.wasm"))) fail("the published default build produced no index.wasm");

for (const d of [cf, proj, out]) rmSync(d, { recursive: true, force: true });
console.log("\nsmoke: OK — published package's DEFAULT (orchestrate) build produced a wasm");
