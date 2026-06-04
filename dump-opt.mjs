// Dump the WHOLE-PROGRAM optimized MIR for one module, linked with the given
// fixtures (so cross-module dict elimination + impurify actually fire).
//
//   node dump-opt.mjs Eff Eff Effect Effect.Unsafe Control.Applicative ...
//   (first arg = module to print; rest = fixtures to link)
import { readFileSync } from "node:fs";
import { parseModule } from "./output/PureScript.Backend.Wasm.Compiler/index.js";
import { optimizeProgram } from "./output/PureScript.Backend.Wasm.MiddleEnd/index.js";
import { printModule } from "./output/PureScript.Backend.Wasm.MiddleEnd.Print/index.js";
import { effectfulForeignNames } from "./output/PureScript.Backend.Wasm.Intrinsics/index.js";

const [target, ...names] = process.argv.slice(2);
const modules = names.map((n) => {
  const parsed = parseModule(readFileSync(`compiler/test/fixtures/${n}.corefn.json`, "utf8"));
  if (parsed.constructor.name !== "Right") {
    console.error(`parse failed for ${n}: ${parsed.value0}`);
    process.exit(1);
  }
  return parsed.value0;
});
const optimized = optimizeProgram(true)(effectfulForeignNames)(modules);
const mod = optimized.find((m) => m.name.join(".") === target);
console.log(printModule(mod));
