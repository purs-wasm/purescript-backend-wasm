// CLI-integration regression test (ulib shadows, ADR 0028): the `purs-wasm build` link step swaps
// the user's `Control.Apply` / `Control.Bind` / `Data.Eq` / `Data.Ord` for the ulib shadows, whose
// array HOFs (`arrayApply` / `arrayBind` / `eqArrayImpl` / `ordArrayImpl`) are reimplemented in
// PureScript over `Wasm.Array` so the element closures specialize. `ulib check` already guards the
// shadows' *interface*; this guards their *runtime semantics*. Builds `Examples.HelloWorld.
// ArrayShadowCheck` (a stable fixture whose `check n :: Int -> Int` runs all four ops on arrays
// built from the runtime arg and returns a 4-bit pass mask — 15 iff every op matched the registry
// semantics). The export is i32-in/i32-out, so it needs no marshalling.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("ulibShadow: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
// The shadows must be installed into the lib first (CI does `ulib install` before the bench/test
// steps; do it here too so the test is self-contained).
execFileSync("node", ["purs-wasm/index.dev.js", "ulib", "install"], { cwd: repo, stdio: "inherit" });

const compiled = mkdtempSync(join(tmpdir(), "ulibshadow-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "ulibshadow-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.dev.js", "build", "-e", "Examples.HelloWorld.ArrayShadowCheck", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const bytes = readFileSync(join(bundle, "index.wasm"));
// instantiate(Module, …) resolves to the Instance directly (the {module, instance} wrapper is only
// for the bufferSource overload), and `wasm-merge` folded the runtime in, so no imports are needed.
const inst = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
if (typeof inst.exports.check !== "function") fail("export `check` is not a function");

// `check n` returns 15 (all four shadows correct) for any n; sweep a few so a constant-fold or an
// off-by-one in a single shadow's loop surfaces. bit0 apply, bit1 bind, bit2 eq, bit3 ord.
for (const n of [0, 1, 5, -3]) {
  const r = inst.exports.check(n);
  if (r !== 15) {
    const bits = ["apply", "bind", "eq", "ord"].filter((_, i) => !(r & (1 << i)));
    fail(`check(${n}) = ${r} (expected 15); failing shadow(s): ${bits.join(", ") || "none?"}`);
  }
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("ulibShadow: OK — Control.Apply/Control.Bind/Data.Eq/Data.Ord shadows run correctly on wasm");
