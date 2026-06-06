// Assemble every `ulib/<Module>/foreign.wat` to `foreign.wasm` (ADR 0012). A full
// `(module …)` is assembled as-is; a *fragment* (no line starting with `(module`) is wrapped
// as `(module <ulib/_header.wat> <fragment>)` first — mirroring the bin's `assemble`. The
// pre-built `.wasm` is consumed by the e2e harness (which links ulib at instantiation) and
// is also picked up directly by the bin's `resolveForeign` (skipping on-the-fly assembly).
// Run from the repo root: `node build-ulib.mjs`.
import { readFileSync, writeFileSync, readdirSync, existsSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";

const wasmAs = "binaryen/node_modules/binaryen/bin/wasm-as";
const header = readFileSync("ulib/_header.wat", "utf8");

for (const m of readdirSync("ulib")) {
  const wat = `ulib/${m}/foreign.wat`;
  if (!existsSync(wat)) continue;
  const content = readFileSync(wat, "utf8");
  const out = `ulib/${m}/foreign.wasm`;
  const isFullModule = content.split("\n").some((l) => l.trimStart().startsWith("(module"));
  if (isFullModule) {
    execFileSync(wasmAs, [wat, "-o", out, "--all-features"]);
  } else {
    const tmp = `ulib/${m}/.combined.wat`;
    writeFileSync(tmp, `(module\n${header}\n${content}\n)\n`);
    try {
      execFileSync(wasmAs, [tmp, "-o", out, "--all-features"]);
    } finally {
      rmSync(tmp, { force: true });
    }
  }
  console.log("built", out);
}
