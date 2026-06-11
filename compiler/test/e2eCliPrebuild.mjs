// Prebuild step for the CLI-driven e2e suite (ADR 0031 phase 5). Builds every `e2e-fixtures` module
// into a standalone wasm via the REAL `purs-wasm build` pipeline, so `Test.E2E.Cli` can instantiate
// the actual artifact a user would get — one path, not the legacy harness's separate in-process link.
//
// One `spago build` of the fixtures package (shared output), then one `purs-wasm build` per entry
// module into `compiler/test/e2e-build/<Module>/index.wasm`. Run from the repo root (the CLI's
// cwd-relative `runtime/`/`lib` paths and the e2e harness's fixture paths both assume repo root).
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const run = (cmd, args) => execFileSync(cmd, args, { cwd: repo, stdio: "inherit" });

// the entry modules = every `e2e-fixtures/src/**/*.purs`, read from its `module … where` header.
const srcDir = join(repo, "e2e-fixtures/src");
const moduleOf = (file) => {
  const m = readFileSync(file, "utf8").match(/^module\s+([\w.]+)/m);
  if (!m) throw new Error(`no module header in ${file}`);
  return m[1];
};
const walk = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith(".purs") ? [join(dir, e.name)] : [],
  );
const entries = walk(srcDir).map(moduleOf).sort();

// the build tooling the CLI needs: its own compile, the installed ulib lib, and the fixtures' corefn.
run("spago", ["build", "-p", "ulib-tooling"]);
run("node", ["ulib-tooling/index.dev.js", "install"]);
const fixturesOut = "compiler/test/e2e-fixtures-out";
rmSync(join(repo, fixturesOut), { recursive: true, force: true });
run("spago", ["build", "-p", "e2e-fixtures", "--output", fixturesOut]);

// one standalone wasm per entry, where `Test.E2E.Cli.Harness.cliFixture` reads it.
const buildDir = "compiler/test/e2e-build";
rmSync(join(repo, buildDir), { recursive: true, force: true });
for (const m of entries) {
  run("node", ["purs-wasm/index.dev.js", "build", "-e", m, "-I", fixturesOut, "-O", `${buildDir}/${m}`]);
}
console.log(`e2eCliPrebuild: built ${entries.length} fixture(s): ${entries.join(", ")}`);
