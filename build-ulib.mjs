// Assemble every `ulib/<Module>/foreign.wat` to `foreign.wasm` (ADR 0012). A full
// `(module …)` is assembled as-is; a *fragment* (no line starting with `(module`) is wrapped
// as `(module <ulib/_header.wat> <fragment>)` first — mirroring `purs-wasm`'s `assemble`. The
// pre-built `.wasm` is consumed by the e2e harness (which links ulib at instantiation) and
// is also picked up directly by `purs-wasm`'s `resolveForeign` (skipping on-the-fly assembly).
// Run from the repo root: `node build-ulib.mjs`.
//
// Why this stays a `.mjs` and was NOT ported to PureScript (`purs-wasm ulib …`) like the other
// commands: it builds the ADR 0012 *wat* foreign layer — the hand-written `foreign.wat` providers
// for the registry modules that are NOT yet shadowed (ulib shadows, ADR 0028, replace `foreign.wat`
// with PureScript-over-WasmBase). That wat layer is a transitional build *step*, not a user-facing
// command, and is slated for wholesale removal once every provider is absorbed into a shadow /
// WasmBase. Porting it to PureScript now would be effort spent on code we intend to delete; so it
// is left as a build script until the wat layer (and this file with it) is retired as one unit.
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
