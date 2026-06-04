// Bin-integration regression test (ADR 0016): a PRIVATE `foreign import` (not in the
// module's export list) is absent from `externs.cbor`, so resolving it relies on the bin
// reconstructing its signature from `.purs` source — located via spago's `cache-db.json`.
//
// Self-contained: the fixture `compiler/test/fixtures/source-foreign/` holds a pre-built
// `Priv` module (`corefn.json`/`externs.cbor`/`foreign.js` for a private `secretImpl :: Int
// -> Int`, JS `n => n*10`, used by an exported `triple`) plus a `cache-db.json` pointing at
// the committed `Priv.purs` source (path relative to the repo root = the bin's cwd). No
// spago build / example package needed. We bundle it through the CLI and check
// `triple(5) === 50`; without source reconstruction the build fails with "unknown callee".
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const input = "compiler/test/fixtures/source-foreign"; // relative to repo (the bin's cwd)
const fail = (msg) => {
  console.error("sourceForeign: FAIL —", msg);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "bin"], { cwd: repo, stdio: "inherit" });

const bundle = mkdtempSync(join(tmpdir(), "sf-bundle-"));
execFileSync("node", ["bin/index.dev.js", "build", "-e", "Priv", "-I", input, "-O", bundle], {
  cwd: repo,
  stdio: "inherit",
});

const m = await import(pathToFileURL(join(bundle, "Priv", "index.mjs")).href);
if (typeof m.exports.triple !== "function")
  fail(`expected exported triple to be a function, got ${typeof m.exports.triple}`);
const got = m.exports.triple(5);
if (got !== 50) fail(`private foreign secretImpl did not resolve correctly: triple(5) = ${got} (expected 50)`);

// Fallback (ADR 0016, requirement 4): with reconstruction unavailable (cache-db removed so
// the source can't be located), a private foreign with no signature must NOT fail the build
// with "unknown callee" — lowering falls back to an all-opaque host import (the value may
// then be wrong, the accepted trade-off). Assert only that the build completes + is callable.
const fbInput = mkdtempSync(join(tmpdir(), "sf-nocachedb-"));
cpSync(join(repo, input), fbInput, { recursive: true });
rmSync(join(fbInput, "cache-db.json"), { force: true });
const fbBundle = mkdtempSync(join(tmpdir(), "sf-fb-bundle-"));
try {
  execFileSync("node", ["bin/index.dev.js", "build", "-e", "Priv", "-I", fbInput, "-O", fbBundle], {
    cwd: repo,
    stdio: "pipe",
  });
} catch (e) {
  fail(`build must not stop when reconstruction is unavailable (ADR 0016 fallback): ${e.stderr ?? e}`);
}
const fb = await import(pathToFileURL(join(fbBundle, "Priv", "index.mjs")).href);
if (typeof fb.exports.triple !== "function") fail("fallback build did not export triple as a function");

rmSync(bundle, { recursive: true, force: true });
rmSync(fbInput, { recursive: true, force: true });
rmSync(fbBundle, { recursive: true, force: true });
console.log("sourceForeign: OK — resolved from source (triple(5) === 50); unresolved foreign falls back to opaque host import (no build stop)");
