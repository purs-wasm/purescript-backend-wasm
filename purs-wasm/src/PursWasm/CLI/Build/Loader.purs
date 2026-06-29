-- | The JS loader for a program with host imports (ADR 0014): copy each used module's `foreign.js`
-- | into `<bundle>/foreign/<Module>.js`, copy the shared marshalling glue (`marshal.js`) next to
-- | the loader, then write a generic `index.mjs` that instantiates the GC wasm, discovers its
-- | imports at run time, and satisfies each from the matching foreign JS with argument/result
-- | marshalling per the baked manifests. The conversion glue itself lives in the checked-in
-- | `runtime/marshal.js` (`makeMarshal`), shared with the e2e harness (Issue #10).
module PursWasm.CLI.Build.Loader
  ( emitLoader
  , loaderSource
  , rootExportSigs
  , exportNeedsLoader
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (maybe)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, MarshalKind(..), foreignManifestJson)
import PureScript.Backend.Wasm.CLI.Paths (loaderGlue)
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, LOG, info, joinPath, mkdirP, readText, writeText)
import PureScript.Backend.Wasm.CLI.Effect.Log as Log
import PureScript.Backend.Wasm.CLI.Module (printModname)
import Run (Run)
import Type.Row (type (+))

emitLoader
  :: forall r
   . FilePath
  -> Boolean
  -> Boolean
  -> FilePath
  -> FilePath
  -> Array String
  -> Object ForeignImport
  -> String
  -> Run (FS + LOG + r) Unit
emitLoader cliRoot browser executable bundleDir input mods sigs exportManifest = do
  foreignDir <- joinPath [ bundleDir, "foreign" ]
  mkdirP foreignDir
  for_ mods (copyForeign foreignDir)
  marshalDst <- joinPath [ bundleDir, "marshal.js" ]
  readText (loaderGlue cliRoot) >>= maybe (pure unit) (writeText marshalDst)
  -- Mark the whole output as an ESM package, so `marshal.js` and the copied `foreign/*.js` load as
  -- ES modules even when the *user's* project is CommonJS (no `"type": "module"`) — otherwise Node
  -- treats the emitted `.js` as CJS and `import { makeMarshal }` fails.
  pkgJson <- joinPath [ bundleDir, "package.json" ]
  writeText pkgJson
    """{ "type": "module" }
"""
  indexMjs <- joinPath [ bundleDir, "index.mjs" ]
  writeText indexMjs (loaderSource browser executable (manifestJs mods sigs) exportManifest)
  info $ Log.blue (Fmt.fmt @"✓ Wrote {file} (+ {n} foreign module(s))" { file: indexMjs, n: Array.length mods })
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

loaderSource :: Boolean -> Boolean -> String -> String -> String
loaderSource browser executable manifest exportManifest =
  importPrologue
    <>
      """

const MANIFEST = """
    <> manifest
    <>
      """;
const EXPORTS_MANIFEST = """
    <> exportManifest
    <>
      """;

"""
    <> loadMod
    <>
      """

// `E` is a *lazy* view of the (post-instantiation) exports, so the marshalling glue can be built
// before `inst` exists — `wrap` is used while wiring the importObject below. `wasm-merge` folds the
// runtime + foreign providers into this one module, so every primitive is on `inst.exports`.
let inst;
const E = new Proxy({}, { get: (_, p) => inst.exports[p] });
const { eqrefToJs, eqrefFromJs, isRaw, wrap, wrapExport } = makeMarshal(E);

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
// Run module initialization (the CAF globals, ADR 0006) AFTER instantiation, not via the wasm
// `start` section — so a CAF whose init calls a JS foreign that re-enters wasm reaches the
// now-bound instance instead of trapping during instantiation (ADR 0021). `caf_init` is absent
// when the program globalizes no CAFs.
inst.exports.caf_init?.();
// expose the exports as plain JS values. A function export (the type has arguments) is
// wrapped so callers pass/receive JS values; a nullary value binding (a CAF, the type
// has no arguments) is evaluated once here and exposed as the value itself — marshalled
// for a non-raw result — so JS sees `exports.x` as `42` / "hi" / {…}, not a function.
const marshalledExports = {};
for (const name of Object.keys(inst.exports)) {
  if (name === "caf_init") continue; // internal module-init hook, not a user export
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
    <> runMain
  where
  -- `-E/--executable`: run the entry's `main` (a nullary `Effect`, validated in `Build`) on load, so
  -- importing/executing this module *is* running the program. The export stays available too.
  runMain = if executable then "exports.main();\n" else ""
  -- The marshalling wiring and `import('./foreign/<m>.js')` work in both Node and the browser; only
  -- the wasm-bytes load differs (Node reads the sibling file off disk; the browser fetches it).
  importPrologue =
    if browser then """import { makeMarshal } from "./marshal.js";"""
    else
      """import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { makeMarshal } from "./marshal.js";"""
  loadMod =
    if browser then """const mod = await WebAssembly.compileStreaming(fetch(new URL("./index.wasm", import.meta.url)));"""
    else
      """const bytes = readFileSync(fileURLToPath(new URL("./index.wasm", import.meta.url)));
const mod = await WebAssembly.compile(bytes);"""
