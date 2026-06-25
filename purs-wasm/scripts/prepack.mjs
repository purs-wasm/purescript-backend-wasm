// Assemble the publishable package (runs on `npm pack` / `npm publish`): bundle the CLI, then copy
// the runtime assets and the precompiled ulib lib INTO the package, so `<cliRoot>/runtime` and
// `<cliRoot>/lib` resolve once installed (`cliRoot` = the package dir in the published CLI). The lib
// ships PREBUILT (not a postinstall) so it survives `ignore-scripts`. Run inside `nix develop`.
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { rmSync, mkdirSync, cpSync } from "node:fs";
import { fileURLToPath } from "node:url";

const pkg = dirname(dirname(fileURLToPath(import.meta.url))); // purs-wasm/
const repo = dirname(pkg); // repo root
const run = (cmd, args) => execFileSync(cmd, args, { stdio: "inherit", cwd: repo });

// 1. The CLI bundle (bundle/index.js).
run("node", [join(pkg, "scripts", "bundle.mjs")]);

// 2. Runtime assets -> <pkg>/runtime. Assemble `runtime.wasm` from `runtime.wat` first — it is a
//    git-ignored build artifact, so a clean checkout (CI) has only the `.wat`.
const wasmAs = join(repo, "binaryen", "node_modules", "binaryen", "bin", "wasm-as");
run(wasmAs, ["--all-features", join(repo, "runtime", "runtime.wat"), "-o", join(repo, "runtime", "runtime.wasm")]);
const rt = join(pkg, "runtime");
rmSync(rt, { recursive: true, force: true });
mkdirSync(rt, { recursive: true });
for (const f of ["runtime.wasm", "marshal.js"]) cpSync(join(repo, "runtime", f), join(rt, f));

// The repo's single MIT LICENSE -> the package (npm includes it on the package page).
cpSync(join(repo, "LICENSE"), join(pkg, "LICENSE"));

// 3. Precompiled ulib lib -> <pkg>/lib. `ulib-tooling install` compiles the shadows over the resolved
//    package-set sources in `.spago/p` (incl. the `wasm-base` extraPackage, ADR 0031) — so prime
//    `.spago` first by building `bench` (its closure pulls wasm-base + the shadows' deps). `install`
//    (re)builds the lib at <repo>/lib; copy it into the package so it ships in the tarball.
run("spago", ["build", "-p", "bench", "--output", join(repo, "bench", "output")]);
// `ulib-tooling`'s `index.js` runs its compiled output, so build it to `output/` first (a clean
// checkout has not compiled it).
run("spago", ["build", "-p", "ulib-tooling"]);
run("node", [join(repo, "ulib-tooling", "index.js"), "install", "-f"]);
const lib = join(pkg, "lib");
rmSync(lib, { recursive: true, force: true });
cpSync(join(repo, "lib"), lib, { recursive: true });

console.log("\nassembled purs-wasm package: bundle/ + runtime/ + lib/");
