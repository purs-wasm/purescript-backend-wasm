// Build the published CLI bundle: compile the PureScript with the stock backend (its FFI is written
// against that representation — purs-backend-es's differs, breaking the externs-decoder FFI), then
// bundle the entry + its deps (incl. the `cbor` npm package) into a single self-contained ESM at
// `purs-wasm/bundle/index.js` — the file `index.js` imports. `binaryen` is NOT bundled: the CLI runs
// `wasm-merge`/`wasm-as` as child processes, resolved at runtime from the `binaryen` dependency.
//
// Run from the repo root with the nix toolchain on PATH (spago / esbuild).
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const pkg = dirname(dirname(fileURLToPath(import.meta.url))); // purs-wasm/
const repo = dirname(pkg); // repo root
const run = (cmd, args) => execFileSync(cmd, args, { stdio: "inherit", cwd: repo });

// A DEDICATED output dir (not the shared `output/`, which accumulates the whole workspace): build
// only purs-wasm + its deps — JS modules with their co-located `foreign.js` FFI.
const out = join(pkg, ".build");
const bundle = join(pkg, "bundle", "index.js");

// 1. Compile to the stock JS backend output (modules + their foreign.js FFI files).
rmSync(out, { recursive: true, force: true });
run("spago", ["build", "-p", "purs-wasm", "--output", out]);

// 2. Bundle the entry module + all its imports (incl. `cbor`) into one minified ESM.
run("esbuild", [
  join(out, "PursWasm.CLI.Main", "index.js"),
  "--bundle",
  "--minify",
  "--platform=node",
  "--format=esm",
  // `cbor` is CommonJS and `require`s node built-ins (`stream`, …). In an ESM bundle esbuild's
  // `__require` shim otherwise throws "Dynamic require"; defining a real `require` (createRequire)
  // makes the shim delegate to it. (esbuild: `__require = typeof require !== 'undefined' ? require : …`.)
  "--banner:js=import { createRequire as __createRequire } from 'module'; const require = __createRequire(import.meta.url);",
  "--outfile=" + bundle,
]);

console.log("\nwrote " + bundle);
