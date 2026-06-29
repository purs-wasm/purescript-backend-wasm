// Build the published `purwc` worker bundle. The DEFAULT build mode is orchestrate (ADR 0042), which
// spawns `purwc` as a subprocess per build, so the published `purs-wasm` package must ship the worker.
// Mirror `bundle.mjs`: compile the `Purwc` entry with the stock JS backend (its FFI is written against
// that representation), then bundle it + its deps (incl. the `cbor` npm package) into one self-contained
// ESM at `purs-wasm/purwc/bundle/index.js` — the file `purs-wasm/purwc/index.js` imports when shipped.
// `binaryen` is NOT bundled (run as child processes / resolved from the dependency at runtime).
//
// Run from the repo root with the nix toolchain on PATH (spago / esbuild).
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const pkg = dirname(dirname(fileURLToPath(import.meta.url))); // purs-wasm/
const repo = dirname(pkg); // repo root
const run = (cmd, args) => execFileSync(cmd, args, { stdio: "inherit", cwd: repo });

// A dedicated output dir (not the shared `output/`): build only purwc + its deps.
const out = join(pkg, "_build-purwc");
const bundle = join(pkg, "purwc", "bundle", "index.js");

// 1. Compile to the stock JS backend output (modules + their foreign.js FFI files).
rmSync(out, { recursive: true, force: true });
run("spago", ["build", "-p", "purwc", "--output", out]);

// 2. Bundle the `Purwc` entry module + all its imports (incl. `cbor`) into one minified ESM. The
//    `createRequire` banner is needed because `cbor` is CommonJS and `require`s node built-ins.
run("esbuild", [
  join(out, "Purwc", "index.js"),
  "--bundle",
  "--minify",
  "--platform=node",
  "--format=esm",
  "--banner:js=import { createRequire as __createRequire } from 'module'; const require = __createRequire(import.meta.url);",
  "--outfile=" + bundle,
]);

console.log("\nwrote " + bundle);
