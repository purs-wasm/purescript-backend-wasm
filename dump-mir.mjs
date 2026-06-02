// Dump a fixture's middle IR (MIR) via the pretty-printer, for inspecting how
// optimization rewrites it. Build first:  spago build -p compiler
//
//   node dump-mir.mjs [FixtureName]      (default: Cmp)
//
// FixtureName is a module under compiler/test/fixtures/<name>.corefn.json.
import { readFileSync } from "node:fs";
import { parseModule } from "./output/PureScript.Backend.Wasm.Compiler/index.js";
import { translModule } from "./output/PureScript.Backend.Wasm.MiddleEnd.Transl/index.js";
import { printModule } from "./output/PureScript.Backend.Wasm.MiddleEnd.Print/index.js";

const name = process.argv[2] ?? "Cmp";
const src = readFileSync(`compiler/test/fixtures/${name}.corefn.json`, "utf8");
const parsed = parseModule(src);
if (parsed.constructor.name !== "Right") {
  console.error(`parse failed for ${name}: ${parsed.value0}`);
  process.exit(1);
}
console.log(printModule(translModule(parsed.value0)));
