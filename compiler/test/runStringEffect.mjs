// CLI-integration regression test (export marshalling, ADR 0014/0018): a `String -> Effect Unit`
// export must (a) marshal its String argument across as an eqref `$Str` — not the historical i32
// fallback — and (b) expose the `Effect` as a deferred thunk, so `main(s)()` runs it. The compiled
// export carries the `Effect` perform-unit as a trailing param (`Codegen.addExportWrapper`
// synthesises it, exposing only the marshalled arg); the loader returns the thunk and omits the
// perform-unit (`Build.Loader`). Builds the dedicated `Examples.HelloWorld.StrEff` fixture (a stable
// `main :: String -> Effect Unit`); the bug it guards previously failed with "Cannot convert object
// to primitive value".
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("runStringEffect: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
const compiled = mkdtempSync(join(tmpdir(), "runstr-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "runstr-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.js", "build", "-e", "Examples.HelloWorld.StrEff", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const m = await import(pathToFileURL(join(bundle, "index.mjs")).href);
if (typeof m.exports.main !== "function") fail(`main must be a function, got ${typeof m.exports.main}`);
// `String -> Effect Unit`: applying the String must NOT run the effect — it returns a thunk.
const thunk = m.exports.main("Alice");
if (typeof thunk !== "function")
  fail(`main("Alice") must return a deferred Effect thunk, got ${typeof thunk}`);

const out = [];
const orig = console.log;
console.log = (...a) => out.push(a.join(" "));
thunk();
console.log = orig;

const got = out.join("\n");
const want = "Hello, Alice!";
if (got !== want) fail(`output mismatch:\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("runStringEffect: OK — String -> Effect Unit export marshals the arg and runs as a thunk");
