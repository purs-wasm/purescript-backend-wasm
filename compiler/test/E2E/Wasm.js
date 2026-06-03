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

// The recursive FFI marshalling glue (ADR 0014), driven by an `encodeMarshalKind`
// string (`i`/`f`/`b`/`s`/`o` leaves). `E` is the wasm
// instance/runtime exports providing the $Str/$Vals/$Int read & build primitives.
const _enc = new TextEncoder();
const _dec = new TextDecoder();
const strToJs = (E, ref) => {
  const n = E.strLen(ref);
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = E.strByteAt(ref, i);
  return _dec.decode(b);
};
const strFromJs = (E, s) => {
  const b = _enc.encode(s);
  const ref = E.strNew(b.length);
  for (let i = 0; i < b.length; i++) E.strSetByte(ref, i, b[i]);
  return ref;
};
// eqref (a boxed, nested value) → JS, by kind. `k` is a parsed kind: a string leaf
// ("i"/"f"/"b"/"s"/"o"), {a:k} (array), or {r:{field:k}} (record).
export const eqrefToJs = (E, k, ref) => {
  if (typeof k === "string") {
    if (k === "i") return E.unboxInt(ref);
    if (k === "f") return E.unboxNum(ref); // boxed $Num element/field
    if (k === "b") return !!E.unboxBool(ref); // i31ref 0/1 → boolean
    if (k === "s") return strToJs(E, ref);
    return ref;
  }
  if (k.a !== undefined) {
    const n = E.arrayLen(ref);
    const out = new Array(n);
    for (let i = 0; i < n; i++) out[i] = eqrefToJs(E, k.a, E.arrayGet(ref, i));
    return out;
  }
  // record: read each known field by its interned label id
  const out = {};
  for (const name of Object.keys(k.r)) {
    out[name] = eqrefToJs(E, k.r[name], E.proj(ref, E.internStr(strFromJs(E, name))));
  }
  return out;
};
// JS → eqref (a boxed, nested value), by kind.
export const eqrefFromJs = (E, k, val) => {
  if (typeof k === "string") {
    if (k === "i") return E.boxInt(val);
    if (k === "f") return E.boxNum(val);
    if (k === "b") return E.boxBool(val ? 1 : 0);
    if (k === "s") return strFromJs(E, val);
    return val;
  }
  if (k.a !== undefined) {
    const ref = E.arrayNew(val.length);
    for (let i = 0; i < val.length; i++) E.arraySet(ref, i, eqrefFromJs(E, k.a, val[i]));
    return ref;
  }
  // record: recSet each field onto an empty record, keyed by interned label id
  let ref = E.recEmpty();
  for (const name of Object.keys(k.r)) {
    ref = E.recSet(ref, E.internStr(strFromJs(E, name)), eqrefFromJs(E, k.r[name], val[name]));
  }
  return ref;
};
// Wrap a JS foreign so its args/result marshal per `sig`. Top-level scalars (`i`/`f`)
// are raw (a JS number = i32/f64), passed through; everything else is an eqref.
const isRaw = (k) => k === "i" || k === "f";
const marshalWrap = (E, fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefToJs(E, sig.params[i], a)));
  const r = fn(...xs);
  return isRaw(sig.result) ? r : eqrefFromJs(E, sig.result, r);
};

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
export const instantiateMarshalled = (bytes) => (userForeigns) => (manifestJson) => () => {
  const rt = runtime();
  const manifest = JSON.parse(manifestJson); // { "Mod.name": { params: [k…], result: k } }
  // Record marshalling needs `internStr` (program-specific label interning), which
  // lives in the *generated* module, not the runtime; the read/build primitives
  // (proj/recSet/strNew/…) live in `rt`. Expose a merged view that falls through to
  // the generated instance's exports, late-bound (marshalWrap closures only run
  // after `inst` exists).
  let inst;
  const E = new Proxy(rt, { get: (t, p) => (p in t ? t[p] : inst.exports[p]) });
  const imports = { rt };
  for (const mod of Object.keys(userForeigns)) {
    imports[mod] = {};
    for (const name of Object.keys(userForeigns[mod])) {
      const sig = manifest[mod + "." + name];
      imports[mod][name] = sig ? marshalWrap(E, userForeigns[mod][name], sig) : userForeigns[mod][name];
    }
  }
  inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
  return inst;
};

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
