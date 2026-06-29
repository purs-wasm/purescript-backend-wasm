// CLI-integration regression test (Free / `purescript-run` monad): `examples/run` is a port of
// purescript-run's "lovely evening" example — a *recursive* Run computation over a TALK + DINNER
// effect stack, interpreted with `runTalk` / `runDinnerPure` / `runBaseEffect`. Building it
// exercises the eta-expansion that lets purescript-run's point-free recursive interpreter loops
// (`loop = resume f pure`) compile (`Lower.lowerRecBind`); running it checks the interpreter
// performs the effects in order. `main` eats pizzas until the stock (10) runs out, then checks the
// bill (= 10) and complains — so the visible effect is 11×"I'm famished!" then "$10!? Outrageous!".
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("examplesRun: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
const compiled = mkdtempSync(join(tmpdir(), "exrun-out-"));
execFileSync("spago", ["build", "-p", "examples-run", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "exrun-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.js", "build", "-e", "Examples.Run.Main", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const m = await import(pathToFileURL(join(bundle, "index.mjs")).href);
// `main :: Effect (Tuple Bill Unit)` — a nullary Effect, exposed by the loader as a thunk that
// performs when called.
if (typeof m.exports.main !== "function") fail(`main must be a callable Effect thunk, got ${typeof m.exports.main}`);

const out = [];
const orig = console.log;
console.log = (...a) => out.push(a.join(" "));
m.exports.main();
console.log = orig;

const want = [...Array(11).fill("I'm famished!"), "$10!? Outrageous!"];
const got = out;
if (got.length !== want.length || got.some((l, i) => l !== want[i]))
  fail(`Run interpreter output mismatch:\n  got:\n${got.map((l) => "    " + l).join("\n")}`);

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("examplesRun: OK — purescript-run 'lovely evening' builds and runs (11 famished, bill $10)");
