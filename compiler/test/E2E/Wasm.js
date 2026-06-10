import { readFileSync, readdirSync, existsSync } from "node:fs";
// NB: resolved from the *compiled* location `output/Test.E2E.Wasm/foreign.js` (spago copies FFI
// verbatim, no path rewriting), so this is `../../` to the repo root, not `../../../` from source.
import { makeMarshal } from "../../runtime/marshal.js";

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

// The curated library modules (ADR 0012, slice 3): each `ulib/<M>/foreign.wasm`
// (pre-built by `build-ulib.mjs`) is instantiated once against `rt` and supplied as
// the generated module's `<M>` import. `bin`/production merges them with wasm-merge;
// here we wire them at instantiation, mirroring the runtime. The importObject keys an
// app doesn't import are ignored, so this is inert for apps that use no ulib foreign.
let ulibCache = null;
const ulibImports = () => {
  if (ulibCache === null) {
    const rt = runtime();
    ulibCache = { rt };
    for (const m of readdirSync("ulib")) {
      const wasmPath = `ulib/${m}/foreign.wasm`;
      if (existsSync(wasmPath)) {
        const inst = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(wasmPath)), { rt });
        ulibCache[m] = inst.exports;
      }
    }
  }
  return ulibCache;
};

// Source text of every `ulib/<M>/foreign.wat`, for the harness to derive ulib foreign
// signatures (`parseUlibSigs`) — the wasm export is the calling-convention source of
// truth, so a migrated foreign lowers to the right host import even with empty externs.
export const ulibWatSources = () =>
  readdirSync("ulib")
    .filter((m) => existsSync(`ulib/${m}/foreign.wat`))
    .map((m) => ({ mod: m, text: readFileSync(`ulib/${m}/foreign.wat`, "utf8") }));

export const instantiate = (bytes) => () =>
  new WebAssembly.Instance(new WebAssembly.Module(bytes), ulibImports());

// The recursive FFI marshalling glue (ADR 0014/0015) lives in the shared, checked-in
// `runtime/marshal.js` (`makeMarshal(E)`), imported above — the SAME module the generated loader
// uses, so the host-interop conversion has one source of truth (Issue #10). Each consumer below
// builds an `E` (a merged view of the separately-instantiated runtime + the generated module's
// exports) and calls `makeMarshal(E)` for the `wrap`/`eqref*`/`isRaw` it needs.

// Instantiate with the shared runtime plus user host imports (ADR 0014): the
// generated module's `foreign import`s are satisfied from `userImports`, keyed by
// the foreign's source module (e.g. { "Example.FFI": { addOne } }).
export const instantiateWith = (bytes) => (userImports) => () =>
  new WebAssembly.Instance(new WebAssembly.Module(bytes), { ...ulibImports(), ...userImports });

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
  // the generated instance's exports, late-bound (the `wrap` closures only run
  // after `inst` exists).
  let inst;
  const E = new Proxy(rt, { get: (t, p) => (p in t ? t[p] : inst.exports[p]) });
  const { wrap } = makeMarshal(E);
  const imports = { ...ulibImports() };
  for (const mod of Object.keys(userForeigns)) {
    imports[mod] = {};
    for (const name of Object.keys(userForeigns[mod])) {
      const sig = manifest[mod + "." + name];
      imports[mod][name] = sig ? wrap(userForeigns[mod][name], sig) : userForeigns[mod][name];
    }
  }
  inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
  return inst;
};

// Call a marshalled wasm export generically (ADR 0014, export direction). `argsJson`
// is a JSON array of JS values; each is marshalled into wasm per the export's param
// kind (the export wrapper exposes marshalRep types — i32/f64 raw, else eqref), the
// export is called, and the result is marshalled back out and JSON-stringified. Covers
// Int/Number/Boolean/String/Array/Record uniformly (not closures — not JSON-able).
export const callExportJson = (inst) => (exportManifestJson) => (name) => (argsJson) => () => {
  const E = new Proxy(runtime(), { get: (t, p) => (p in t ? t[p] : inst.exports[p]) });
  const { eqrefToJs, eqrefFromJs, isRaw } = makeMarshal(E);
  const sig = JSON.parse(exportManifestJson)[name];
  const args = JSON.parse(argsJson);
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefFromJs(sig.params[i], a)));
  const r = inst.exports[name](...xs);
  return JSON.stringify(isRaw(sig.result) ? r : eqrefToJs(sig.result, r));
};

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
