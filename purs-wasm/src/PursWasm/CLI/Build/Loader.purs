-- | The JS loader for a program with host imports (ADR 0014): copy each used module's `foreign.js`
-- | into `<bundle>/foreign/<Module>.js`, then write a generic `index.mjs` that instantiates the
-- | GC wasm, discovers its imports at run time, and satisfies each from the matching foreign JS
-- | with argument/result marshalling per the baked manifests. `loaderSource` is reproduced
-- | verbatim from the prototype (byte-for-byte; its redesign is tracked in Issues #9 / #10).
module PursWasm.CLI.Build.Loader
  ( emitLoader
  , rootExportSigs
  , exportNeedsLoader
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (maybe)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import Fmt as Fmt
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, MarshalKind(..), foreignManifestJson)
import PursWasm.CLI.Effect (FS, FilePath, LOG, info, joinPath, mkdirP, readText, writeText)
import PursWasm.CLI.Module (printModname)
import Run (Run)
import Type.Row (type (+))

emitLoader
  :: forall r
   . FilePath
  -> FilePath
  -> Array String
  -> Object ForeignImport
  -> String
  -> Run (FS + LOG + r) Unit
emitLoader bundleDir input mods sigs exportManifest = do
  foreignDir <- joinPath [ bundleDir, "foreign" ]
  mkdirP foreignDir
  for_ mods (copyForeign foreignDir)
  indexMjs <- joinPath [ bundleDir, "index.mjs" ]
  writeText indexMjs (loaderSource (manifestJs mods sigs) exportManifest)
  info (Fmt.fmt @"Wrote {file} (+ {n} foreign module(s))" { file: indexMjs, n: Array.length mods })
  where
  copyForeign foreignDir m = do
    src <- joinPath [ input, m, "foreign.js" ]
    dst <- joinPath [ foreignDir, m <> ".js" ]
    readText src >>= maybe (pure unit) (writeText dst)

-- | The export marshal signatures for the entry (`roots`) modules: every top-level value of a
-- | root module, keyed by its bare name. A superset of the actually-exported functions — the
-- | loader only wraps names present in `inst.exports`, so extra entries are harmless.
rootExportSigs :: Array (Array String) -> Object ForeignImport -> Object ForeignImport
rootExportSigs roots sigs = Object.fromFoldable do
  s <- Object.values sigs
  if Array.elem s.moduleName (map printModname roots) then [ Tuple s.base s ] else []

-- | Whether a root export needs the JS loader to marshal it: any param/result that is not a raw
-- | scalar (`Int`/`Char` → `i32`, `Number` → `f64`) crosses as an `eqref` and so needs the glue.
exportNeedsLoader :: ForeignImport -> Boolean
exportNeedsLoader s = Array.any nonRaw s.params || nonRaw s.result
  where
  nonRaw = case _ of
    MI32 -> false
    MF64 -> false
    _ -> true

-- | The marshalling manifest as a JSON object literal, keyed by import name `Module.base`.
-- | Restricted to the foreign modules actually linked.
manifestJs :: Array String -> Object ForeignImport -> String
manifestJs mods sigs =
  foreignManifestJson (Array.filter (\s -> Array.elem s.moduleName mods) (Object.values sigs))

loaderSource :: String -> String -> String
loaderSource manifest exportManifest =
  """import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MANIFEST = """ <> manifest
    <>
      """;
const EXPORTS_MANIFEST = """
    <> exportManifest
    <>
      """;

const bytes = readFileSync(fileURLToPath(new URL("./index.wasm", import.meta.url)));
const mod = await WebAssembly.compile(bytes);

let inst;
const enc = new TextEncoder();
const dec = new TextDecoder();
const strToJs = (ref) => {
  const n = inst.exports.strLen(ref);
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = inst.exports.strByteAt(ref, i);
  return dec.decode(b);
};
const strFromJs = (s) => {
  const b = enc.encode(s);
  const ref = inst.exports.strNew(b.length);
  for (let i = 0; i < b.length; i++) inst.exports.strSetByte(ref, i, b[i]);
  return ref;
};
// `k` is a parsed encodeMarshalKind value: a string leaf ("i"/"f"/"b"/"s"/"o"), {a:k}
// (array), {fn:[pk,rk]} (function), or {r:{field:k}} (record). eqref → JS, by kind.
const eqrefToJs = (k, ref) => {
  if (typeof k === "string") {
    if (k === "i") return inst.exports.unboxInt(ref);
    if (k === "f") return inst.exports.unboxNum(ref);
    if (k === "b") return !!inst.exports.unboxBool(ref);
    if (k === "s") return strToJs(ref);
    return ref;
  }
  if (k.a !== undefined) {
    const n = inst.exports.arrayLen(ref);
    const out = new Array(n);
    for (let i = 0; i < n; i++) out[i] = eqrefToJs(k.a, inst.exports.arrayGet(ref, i));
    return out;
  }
  if (k.fn !== undefined) {
    // a wasm $Clo → a JS function: marshal the arg in, apply via the trampoline, marshal out
    const [pk, rk] = k.fn;
    return (a) => eqrefToJs(rk, inst.exports.applyClo(ref, eqrefFromJs(pk, a)));
  }
  // Effect a (export side): wasm already performed it, so the value IS the inner result
  if (k.eff !== undefined) return eqrefToJs(k.eff, ref);
  // record: read each known field by its interned label id
  const out = {};
  for (const name of Object.keys(k.r)) {
    out[name] = eqrefToJs(k.r[name], inst.exports.proj(ref, inst.exports.internStr(strFromJs(name))));
  }
  return out;
};
// JS → eqref (a boxed, nested value), by kind.
const eqrefFromJs = (k, val) => {
  if (typeof k === "string") {
    if (k === "i") return inst.exports.boxInt(val);
    if (k === "f") return inst.exports.boxNum(val);
    if (k === "b") return inst.exports.boxBool(val ? 1 : 0);
    if (k === "s") return strFromJs(val);
    return val;
  }
  if (k.a !== undefined) {
    const ref = inst.exports.arrayNew(val.length);
    for (let i = 0; i < val.length; i++) inst.exports.arraySet(ref, i, eqrefFromJs(k.a, val[i]));
    return ref;
  }
  if (k.fn !== undefined) {
    throw new Error("FFI: marshalling a JS function into wasm is not yet supported (ADR 0014, closure direction 2)");
  }
  // record: recSet each field onto an empty record, keyed by interned label id
  let ref = inst.exports.recEmpty();
  for (const name of Object.keys(k.r)) {
    ref = inst.exports.recSet(ref, inst.exports.internStr(strFromJs(name)), eqrefFromJs(k.r[name], val[name]));
  }
  return ref;
};
const isRaw = (k) => k === "i" || k === "f";
// PureScript FFI foreigns are *curried* (`a => b => c`), so apply one argument at a
// time — `fn(...xs)` would pass only the first to a curried foreign (a multi-arg
// foreign like `unfoldrArrayImpl` would return a function, not its result).
const applyCurried = (fn, xs) => xs.reduce((g, x) => g(x), fn);
// import direction: wasm calls the JS foreign — args wasm→JS, result JS→wasm
const wrap = (fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefToJs(sig.params[i], a)));
  // an effectful foreign (`{eff:k}` result): applying the value args yields the Effect
  // thunk, which we RUN here (the perform is on the JS side), then marshal the inner
  // result by `k` (ADR 0015). A *nullary* Effect foreign (`Effect a`, no value args, e.g.
  // `random`) IS the thunk, so we must not pre-call it. Unit (undefined) → boxed 0.
  if (sig.result && sig.result.eff !== undefined) {
    const thunk = applyCurried(fn, xs);
    const ran = thunk();
    const k = sig.result.eff;
    if (ran === undefined || ran === null) return inst.exports.boxInt(0);
    return isRaw(k) ? ran : eqrefFromJs(k, ran);
  }
  const r = applyCurried(fn, xs);
  return isRaw(sig.result) ? r : eqrefFromJs(sig.result, r);
};
// export direction: JS calls the wasm export — args JS→wasm, result wasm→JS
const wrapExport = (fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefFromJs(sig.params[i], a)));
  const r = fn(...xs);
  return isRaw(sig.result) ? r : eqrefToJs(sig.result, r);
};

const importObject = {};
const nsCache = {};
for (const { module, name } of WebAssembly.Module.imports(mod)) {
  if (!nsCache[module]) {
    nsCache[module] = await import(new URL(`./foreign/${module}.js`, import.meta.url).href);
    importObject[module] = {};
  }
  const sig = MANIFEST[module + "." + name];
  importObject[module][name] = sig ? wrap(nsCache[module][name], sig) : nsCache[module][name];
}

inst = await WebAssembly.instantiate(mod, importObject);
// expose the exports as plain JS values. A function export (the type has arguments) is
// wrapped so callers pass/receive JS values; a nullary value binding (a CAF, the type
// has no arguments) is evaluated once here and exposed as the value itself — marshalled
// for a non-raw result — so JS sees `exports.x` as `42` / "hi" / {…}, not a function.
const marshalledExports = {};
for (const name of Object.keys(inst.exports)) {
  const e = inst.exports[name];
  const sig = EXPORTS_MANIFEST[name];
  if (!sig || typeof e !== "function") {
    marshalledExports[name] = e;
  } else if (sig.params.length === 0 && sig.result && sig.result.eff !== undefined) {
    // an `Effect a` value binding (e.g. `main`) is a *deferred computation*, not a CAF:
    // expose it as a JS thunk `() => a` so the effect runs when CALLED, not at load
    // (matching `Effect a ≃ () => a`). The wasm export performs it on each call.
    const k = sig.result.eff;
    marshalledExports[name] = () => {
      const r = e();
      return isRaw(k) ? r : eqrefToJs(k, r);
    };
  } else if (sig.params.length === 0 && e.length === 0) {
    // a genuine CAF (source value, compiled to a nullary function): call it once at load
    // and expose the resulting value, so it reads as a value on the JS side, not a thunk.
    const r = e();
    marshalledExports[name] = isRaw(sig.result) ? r : eqrefToJs(sig.result, r);
  } else if (sig.params.length === 0) {
    // the source type is a value but the backend compiled it to a *function* — a monadic
    // value (e.g. `TypingM a`) collapsed to take its reader/state arguments (ADR 0015). It
    // is not a JS-usable CAF, and calling it with no args would trap (`illegal cast` on the
    // missing argument), so expose the raw wasm export rather than evaluating it at load.
    marshalledExports[name] = e;
  } else if (sig.result && sig.result.eff !== undefined) {
    // a function returning `Effect a` (e.g. `main :: String -> Effect Unit`): marshal the value
    // args, then return a JS thunk that performs the effect when CALLED — `f(x)()` — matching
    // `Effect a ≃ () => a` (ADR 0015). The wasm export carries the trailing perform-unit param
    // (ADR 0018), which we leave off (as for a nullary Effect); the inner result is marshalled.
    const k = sig.result.eff;
    marshalledExports[name] = (...args) => {
      const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefFromJs(sig.params[i], a)));
      return () => {
        const r = e(...xs);
        return isRaw(k) ? r : eqrefToJs(k, r);
      };
    };
  } else {
    marshalledExports[name] = wrapExport(e, sig);
  }
}
export const exports = marshalledExports;
export default exports;
"""
