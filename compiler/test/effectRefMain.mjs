// CLI-integration regression test (ADR 0019): the full `examples/effect-ref` `main` — a do
// block mixing native `Ref` (new/write/modify_), `whenM`/`when` with a *host foreign*
// (`Console.log`) body, `<#>`, and `>>=` + `show`. It exercises both Effect-collapse fixes:
//   * generalized effect reflection (a host foreign in value/branch position is a thunk, not
//     an eager call) — so `when b (Console.log …)` no longer `illegal cast`s;
//   * map/apply impurification — so `void`/`<#>` keep their effect.
// We build it through the CLI, run `exports.main()` in a subprocess, and assert the printed
// output (a regression here was either a crash or a dropped line).
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const fail = (msg) => {
  console.error("effectRefMain: FAIL —", msg);
  process.exit(1);
};

const compiled = mkdtempSync(join(tmpdir(), "effref-main-out-"));
execFileSync("spago", ["build", "-p", "examples-effect-ref", "--output", compiled], { cwd: repo, stdio: "inherit" });
execFileSync("spago", ["build", "-p", "purs-wasm"], { cwd: repo, stdio: "inherit" });
const bundle = mkdtempSync(join(tmpdir(), "effref-main-bundle-"));
execFileSync(
  "node",
  ["purs-wasm/index.js", "build", "-e", "Examples.EffRef.Main", "-I", compiled, "-O", bundle],
  { cwd: repo, stdio: "inherit" },
);

const entry = pathToFileURL(join(bundle, "index.mjs")).href;
let out;
try {
  out = execFileSync("node", ["-e", `import(${JSON.stringify(entry)}).then(m => m.exports.main())`], {
    cwd: repo,
    encoding: "utf8",
  });
} catch (e) {
  fail(`main() crashed: ${String(e.stderr ?? e).split("\n").slice(0, 3).join(" ")}`);
}

rmSync(compiled, { recursive: true, force: true });
rmSync(bundle, { recursive: true, force: true });

// new 0 → write 1 → whenM (read >= 0) (log "…non-negative!") → modify_ (*2) → read = 2
const expected = ["The ref is non-negative!", "The final result is 2"];
for (const line of expected) {
  if (!out.includes(line)) fail(`expected output to contain ${JSON.stringify(line)}; got:\n${out}`);
}
console.log("effectRefMain: OK — full Effect example (Ref + when host-foreign + modify_ + show) runs:", JSON.stringify(out.trim().split("\n")));
