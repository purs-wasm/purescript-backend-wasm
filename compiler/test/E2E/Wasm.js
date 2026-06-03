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

// Instantiate with String-marshalling host imports (ADR 0014, L2). `userForeigns`
// is `{ Module: { fn: jsImpl } }` (raw JS taking/returning JS strings); `manifest`
// is `{ Module: { fn: { params: ["string"|"raw"…], result: "string"|"raw" } } }`.
// Each "string" position is converted via the runtime's `$Str` read/write exports —
// `$Str` → JS string on the way in, JS string → `$Str` on the way out.
export const instantiateMarshalled = (bytes) => (userForeigns) => (manifest) => () => {
  const rt = runtime();
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const fromStr = (ref) => {
    const n = rt.strLen(ref);
    const b = new Uint8Array(n);
    for (let i = 0; i < n; i++) b[i] = rt.strByteAt(ref, i);
    return dec.decode(b);
  };
  const toStr = (s) => {
    const b = enc.encode(s);
    const ref = rt.strNew(b.length);
    for (let i = 0; i < b.length; i++) rt.strSetByte(ref, i, b[i]);
    return ref;
  };
  const wrap = (fn, sig) => (...args) => {
    const xs = args.map((a, i) => (sig.params[i] === "string" ? fromStr(a) : a));
    const r = fn(...xs);
    return sig.result === "string" ? toStr(r) : r;
  };
  const imports = { rt };
  for (const mod of Object.keys(userForeigns)) {
    imports[mod] = {};
    const sigs = manifest[mod] || {};
    for (const name of Object.keys(userForeigns[mod])) {
      imports[mod][name] = sigs[name] ? wrap(userForeigns[mod][name], sigs[name]) : userForeigns[mod][name];
    }
  }
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
};

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
