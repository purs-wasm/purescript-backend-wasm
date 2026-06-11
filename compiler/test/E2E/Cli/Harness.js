import { readFileSync } from "node:fs";

// Instantiate a fixture's prebuilt standalone wasm (ADR 0031 phase 5). The CLI already merged the
// runtime + every ulib foreign provider into `index.wasm`, so it instantiates with NO imports — the
// opposite of the legacy harness, which wired `rt` + `ulib/<M>/foreign.wasm` at instantiation. Path
// is repo-root-relative (spago test runs from the repo root, like the legacy fixture paths).
export const cliFixture = (mod) => () => {
  const bytes = readFileSync(`compiler/test/e2e-build/${mod}/index.wasm`);
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
};

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();
export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);
export const callI32x2 = (inst) => (name) => (a) => (b) => () => inst.exports[name](a, b);
export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () => inst.exports[name](a, b, c);
