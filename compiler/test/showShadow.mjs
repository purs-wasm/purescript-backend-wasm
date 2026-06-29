// CLI-integration regression test (ulib Data.Show shadow, ADR 0028 / 0030): the `purs-wasm build`
// link step swaps the registry `Data.Show` for the ulib shadow, which reimplements showIntImpl /
// showCharImpl / showStringImpl / showArrayImpl in PureScript over `Wasm.String` / `Wasm.Char` /
// `Wasm.Array` (showNumberImpl stays foreign — the wat provides float→string). `ulib check` guards
// the interface; this guards the runtime semantics. Builds `Examples.HelloWorld.ShowShadowCheck`,
// whose `check n :: Int -> Int` runs 16 `show` cases (Int incl. min/negative, Char/String escaping
// over 1/2/3-byte code points, arrays, a record, the foreign Number path, Bool/Unit) and returns a
// 16-bit pass mask — 65535 iff every case matched. The export is i32-in/i32-out (no marshalling).
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("showShadow: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "ulib-tooling"], { cwd: repo, stdio: "inherit" });
execFileSync("node", ["ulib-tooling/index.js", "install"], { cwd: repo, stdio: "inherit" });

const compiled = mkdtempSync(join(tmpdir(), "showshadow-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "showshadow-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.js", "build", "-e", "Examples.HelloWorld.ShowShadowCheck", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const bytes = readFileSync(join(bundle, "index.wasm"));
const inst = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
if (typeof inst.exports.check !== "function") fail("export `check` is not a function");

const NAMES = [
  "int42", "int-7", "minInt", "char-a", "char-nl", "char-multibyte", "char-quote", "str-hi",
  "str-nl", "str-quote", "str-multibyte", "arr-int", "arr-str", "record", "number(foreign)", "bool/unit",
];
const EXPECT = 2 ** NAMES.length - 1; // 65535
const r = inst.exports.check(0);
if (r !== EXPECT) {
  const fails = NAMES.filter((_, i) => !(r & (1 << i)));
  fail(`check(0) = ${r} (expected ${EXPECT}); failing case(s): ${fails.join(", ") || "none?"}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("showShadow: OK — Data.Show shadow runs correctly on wasm (UTF-8 escaping, decimal, arrays/record; foreign showNumber via wat)");
