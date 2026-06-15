import { readFileSync } from "node:fs";

// Instantiate a fixture's prebuilt standalone wasm (ADR 0031 phase 5). The CLI already merged the
// runtime + every ulib foreign provider into `index.wasm`, so it instantiates with NO imports — the
// opposite of the legacy harness, which wired `rt` + `ulib/<M>/foreign.wasm` at instantiation. Path
// is repo-root-relative (spago test runs from the repo root, like the legacy fixture paths).
export const cliFixture = (mod) => () => {
  const bytes = readFileSync(`compiler/test/e2e-build/${mod}/index.wasm`);
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
  // Run CAF initialization (ADR 0006) the way a consumer does. A self-contained build runs it via
  // the wasm `start` section; a build that expects a loader exports `caf_init` instead, for the
  // loader to run after instantiation (ADR 0021). This raw harness has no loader, so call it here —
  // idempotent for the start-section case (pure CAFs recompute to the same values).
  instance.exports.caf_init?.();
  return instance;
};

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();
export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);
export const callI32x2 = (inst) => (name) => (a) => (b) => () => inst.exports[name](a, b);
export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () => inst.exports[name](a, b, c);
