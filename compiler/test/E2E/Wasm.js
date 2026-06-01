import { readFileSync } from "node:fs";

export const readFixture = (path) => () => readFileSync(path, "utf8");

// The shared runtime (ADR 0010): instantiate runtime.wasm once and supply its
// exports as the generated module's "rt" imports. `bin`/production merges the two
// with wasm-merge instead; here we wire them at instantiation.
let rtExports = null;
const runtime = () => {
  if (rtExports === null) {
    const bytes = readFileSync("runtime/runtime.wasm");
    rtExports = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  }
  return rtExports;
};

export const instantiate = (bytes) => () =>
  new WebAssembly.Instance(new WebAssembly.Module(bytes), { rt: runtime() });

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
