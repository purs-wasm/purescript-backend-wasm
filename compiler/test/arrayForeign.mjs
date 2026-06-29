// CLI-integration regression test (ulib `Data.Array` KEPT FOREIGNS, ADR 0028/0031 §6.1): unlike the
// pure-PS array HOFs (`ulibShadow`), `Data.Array`'s readers (`reverse` / `sliceImpl` / `indexImpl` /
// `unconsImpl` / `rangeImpl` / `length`) stay as wasm `foreign import`s, provided by the lib's
// `$LIB/Data.Array/foreign.wasm`. Their calling-convention signatures (notably `rangeImpl`'s
// `(param i32)`) cannot be reconstructed from externs alone, so the build reads them from the lib's
// `$LIB/Data.Array/foreign.wat` (shipped beside the wasm at install). This builds
// `Examples.HelloWorld.ArrayForeignCheck` and instantiates it with NO imports (`{}`): a wrong sig
// makes the `wasm-merge` of app + foreign.wasm fail at build, so reaching a green run proves the
// lib-wat sig path works end to end. `check n :: Int -> Int` returns 63 iff all six readers pass.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (m) => {
  console.error("arrayForeign: FAIL —", m);
  process.exit(1);
};

execFileSync("spago", ["build", "-p", "ulib-tooling"], { cwd: repo, stdio: "inherit" });
execFileSync("node", ["ulib-tooling/index.js", "install"], { cwd: repo, stdio: "inherit" });

const compiled = mkdtempSync(join(tmpdir(), "arrfgn-out-"));
execFileSync("spago", ["build", "-p", "examples-helloworld", "--output", compiled], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "arrfgn-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.js", "build", "-e", "Examples.HelloWorld.ArrayForeignCheck", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const bytes = readFileSync(join(bundle, "index.wasm"));
// instantiate with NO imports: a wrong foreign sig would already have failed wasm-merge at build.
const inst = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
if (typeof inst.exports.check !== "function") fail("export `check` is not a function");

const NAMES = ["reverse", "sliceImpl", "indexImpl(in)", "indexImpl(oob)", "unconsImpl+length", "length"];
const EXPECT = 2 ** NAMES.length - 1; // 6 bits → 63
const r = inst.exports.check(3);
if (r !== EXPECT) {
  const fails = NAMES.filter((_, i) => !(r & (1 << i)));
  fail(`check(3) = ${r} (expected ${EXPECT}); failing: ${fails.join(", ") || "none?"}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });
console.log("arrayForeign: OK — Data.Array kept foreigns (reverse/slice/index/uncons/range/length) run standalone, sigs from lib wat");
