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

// Instantiate with the shared runtime plus user host imports (ADR 0014): the
// generated module's `foreign import`s are satisfied from `userImports`, keyed by
// the foreign's source module (e.g. { "Example.FFI": { addOne } }).
export const instantiateWith = (bytes) => (userImports) => () =>
  new WebAssembly.Instance(new WebAssembly.Module(bytes), { rt: runtime(), ...userImports });

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
