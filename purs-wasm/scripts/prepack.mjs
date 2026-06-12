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

// 2. Runtime assets -> <pkg>/runtime.
const rt = join(pkg, "runtime");
rmSync(rt, { recursive: true, force: true });
mkdirSync(rt, { recursive: true });
for (const f of ["runtime.wasm", "marshal.js"]) cpSync(join(repo, "runtime", f), join(rt, f));

// 3. Precompiled ulib lib -> <pkg>/lib. `ulib-tooling install` (re)builds it at <repo>/lib; copy it
//    into the package so it ships in the tarball.
run("node", [join(repo, "ulib-tooling", "index.dev.js"), "install", "-f"]);
const lib = join(pkg, "lib");
rmSync(lib, { recursive: true, force: true });
cpSync(join(repo, "lib"), lib, { recursive: true });

console.log("\nassembled purs-wasm package: bundle/ + runtime/ + lib/");
