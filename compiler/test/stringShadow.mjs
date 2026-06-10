// CLI-integration regression test (ulib Data.String.CodeUnits shadow, ADR 0028 / 0030): the
// `purs-wasm build` link step swaps the registry `Data.String.CodeUnits` (UTF-16 JS foreigns) for
// the ulib shadow, which reimplements them in PureScript over `Wasm.String` with **code-point**
// semantics on the UTF-8 `$Str`. `ulib check` guards the interface; this guards the runtime
// semantics of the hand-written UTF-8 codec. Builds `Examples.HelloWorld.StringShadowCheck`, whose
// `check n :: Int -> Int` runs 16 operations on the mixed-width string "aé☺b" (1/2/3-byte code
// points) and returns a 16-bit pass mask — 65535 iff every operation matched the code-point
// semantics. The export is i32-in/i32-out, so it needs no marshalling.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("stringShadow: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
execFileSync("node", ["purs-wasm/index.dev.js", "ulib", "install"], { cwd: repo, stdio: "inherit" });

const compiled = mkdtempSync(join(tmpdir(), "strshadow-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "strshadow-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.dev.js", "build", "-e", "Examples.HelloWorld.StringShadowCheck", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const bytes = readFileSync(join(bundle, "index.wasm"));
const inst = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
if (typeof inst.exports.check !== "function") fail("export `check` is not a function");

const NAMES = [
  "length", "take", "drop", "charAt-in", "charAt-oob", "toCharArray", "fromCharArray", "singleton",
  "splitAt", "slice", "indexOf", "lastIndexOf", "countPrefix", "stripPrefix", "uncons", "toChar",
];
const r = inst.exports.check(0);
if (r !== 65535) {
  const fails = NAMES.filter((_, i) => !(r & (1 << i)));
  fail(`check(0) = ${r} (expected 65535); failing op(s): ${fails.join(", ") || "none?"}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("stringShadow: OK — Data.String.CodeUnits shadow runs correctly on wasm (UTF-8 code-point semantics, 1/2/3-byte)");
