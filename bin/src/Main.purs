module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), isNothing, maybe)
import Data.List.NonEmpty as NEL
import Data.String (Pattern(..))
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, throwError, try)
import Effect.Class (liftEffect)
import Effect.Class.Console (logShow)
import Effect.Class.Console as Console
import Effect.Exception (error)
import Fmt as Fmt
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.FS.Perms (permsAll)
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as Process
import Node.Cbor (decodeFirst)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Compiler (compileModules, parseModule)
import PureScript.Backend.Wasm.Externs (foreignSigs)
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, foreignManifestJson)
import PureScript.CoreFn (ModuleName, toModuleName)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Unsafe.Coerce (unsafeCoerce)
import Version as Version

-- | Run an external tool synchronously (used for `wasm-merge` / `wasm-dis`).
foreign import execFileImpl :: String -> Array String -> Effect Unit

execFile :: String -> Array String -> Aff Unit
execFile cmd args = liftEffect (execFileImpl cmd args)

-- | The host-import module names a wasm binary declares (the user `foreign import`
-- | modules a JS loader must satisfy; ADR 0014).
foreign import importModulesImpl :: Uint8Array -> Effect (Array String)

type BuildOption =
  { input :: FilePath
  , outDir :: FilePath
  , entryModules :: NEL.NonEmptyList String
  , text :: Boolean
  , debug :: Boolean
  , noOpt :: Boolean
  }

buildOptionsParser :: ArgParser BuildOption
buildOptionsParser =
  ArgParser.fromRecord
    { input:
        ArgParser.argument [ "-I", "--input" ]
          "Path to input directory containing PureScript compiler's artifacts (namely, corefn.json and externs.cbor)\n\
          \Defaults to './output'."
          # ArgParser.default (Path.concat [ ".", "output" ])
    , outDir:
        ArgParser.argument [ "-O", "--output" ]
          "The output directory the bundled wasm is placed in.\n\
          \Defaults to './output-wasm'."
          # ArgParser.default (Path.concat [ ".", "output-wasm" ])
    , entryModules: ArgParser.many1 $
        ArgParser.argument [ "-e", "--entry" ]
          "The name of an entry module (whose exports are kept). You can pass several."
    , text:
        ArgParser.flag [ "-t", "--text" ]
          "Emit the WebAssembly text format (.wat) instead of a binary .wasm."
          # ArgParser.boolean
    , debug:
        ArgParser.flag [ "-g", "--debug" ]
          "Debug build: skip the Binaryen optimizer (keeps the wasm close to the\n\
          \emitted IR; also the future home of source-map output)."
          # ArgParser.boolean
    , noOpt:
        ArgParser.flag [ "--no-opt" ]
          "Skip the middle-end optimization (dictionary elimination); lambda lifting\n\
          \still runs. Use to build an unoptimized baseline for benchmarking."
          # ArgParser.boolean
    }

data Command = Build BuildOption

commandParser :: ArgParser Command
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "build" ]
        "Build a wasm module from a PureScript project's compiler artifacts"
        do
          Build <$> buildOptionsParser <* ArgParser.flagHelp
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parseArgs :: Effect (Either ArgParser.ArgError Command)
parseArgs = do
  cliArgs <- Array.drop 2 <$> Process.argv
  pure $ ArgParser.parseArgs "purs-backend-wasm"
    "A PureScript backend for WebAssembly (with GC)"
    commandParser
    cliArgs

-- | A module name as its on-disk directory / dotted form (`Data.Maybe`).
printModname :: ModuleName -> String
printModname = Str.joinWith "."

-- | `-e Data.Maybe` names the module `["Data", "Maybe"]` — the root form
-- | `lowerModules` expects.
entryRoot :: String -> ModuleName
entryRoot = Str.split (Pattern ".")

main :: FilePath -> Effect Unit
main _cliRoot =
  parseArgs >>= case _ of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Build args) -> launchAff_ (buildCmd args)

-- | Link every module found under `input` into one wasm and write it to
-- | `output`. Paths are resolved against the current working directory.
buildCmd :: BuildOption -> Aff Unit
buildCmd args = do
  logShow args
  -- Each subdirectory of `input` is named by its dotted module name; sort for a
  -- deterministic build (ADR 0009).
  entries <- FS.readdir args.input
  let named = Array.sort (Array.mapMaybe toModuleName entries)
  -- `Prim` and the other built-in pseudo-modules have an output directory but no
  -- `corefn.json` (they are compiler intrinsics with no CoreFn); skip any module
  -- whose CoreFn artifact is absent rather than failing the whole build.
  mods <- Array.filterA (\mod -> isNothing <$> FS.access (Path.concat [ args.input, printModname mod, "corefn.json" ])) named
  Console.log (Fmt.fmt @"Linking {count} module(s) from {dir}" { count: Array.length mods, dir: args.input })
  modules <- for mods \mod -> do
    source <- FS.readTextFile UTF8 (Path.concat [ args.input, printModname mod, "corefn.json" ])
    case parseModule source of
      Left err -> throwError (error (printModname mod <> ": " <> err))
      Right m -> pure m
  -- Each module's `externs.cbor` carries the top-level type information CoreFn
  -- erased; it drives type-directed lowering (front B). A module without readable
  -- or decodable externs is simply skipped — its constructors fall back to boxed.
  externs <- map Array.catMaybes $ for mods \mod -> do
    result <- try do
      buf <- FS.readFile (Path.concat [ args.input, printModname mod, "externs.cbor" ])
      fgn <- decodeFirst buf
      pure (runDecoder decoder fgn)
    pure case result of
      Right (Right ef) -> Just ef
      _ -> Nothing
  let roots = map entryRoot (Array.fromFoldable args.entryModules)
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt }
  -- one bundle per build: place it in a directory named after the (first) entry
  -- module, mirroring purs / backend-es (`<output>/<Entry>/index.{wasm,wat}`), so
  -- companion artifacts (a .wat, a future JS loader / source map) sit together.
  let bundleDir = Path.concat [ args.outDir, NEL.head args.entryModules ]
  FS.mkdir' bundleDir { recursive: true, mode: permsAll }
  -- The generated module imports the shared runtime (`$rt.*`, ADR 0010). Compile
  -- it, then merge `runtime.wasm` in with `wasm-merge` to produce one
  -- self-contained wasm (imports resolved); `--text` disassembles that result.
  let appPath = Path.concat [ bundleDir, "app.wasm" ]
  let wasmPath = Path.concat [ bundleDir, "index.wasm" ]
  liftEffect (compileModules opts roots modules externs) >>= case _ of
    Left err -> throwError (error err)
    Right bytes -> do
      -- the user `foreign import` modules the wasm needs (ADR 0014); empty for a
      -- self-contained program (only intrinsic / runtime foreigns)
      foreignMods <- liftEffect (importModulesImpl bytes)
      FS.writeFile appPath (unsafeCoerce bytes)
      -- Resolve each foreign module along the ADR 0014 ladder, packaging stage: a
      -- `foreign.wasm`/`foreign.wat` provider is merged in (self-contained, no
      -- marshalling — it speaks the internal ABI); otherwise it falls back to JS
      -- (`foreign.js`, satisfied by the generated loader).
      providers <- for foreignMods (resolveForeign args.input bundleDir)
      let wasmProvided = Array.mapMaybe (\p -> Tuple p.name <$> p.wasm) providers
      let jsProvided = Array.mapMaybe (\p -> if isNothing p.wasm then Just p.name else Nothing) providers
      let mergeForeigns = wasmProvided >>= \(Tuple name wp) -> [ wp, name ]
      execFile wasmMergeBin ([ appPath, "app", runtimeWasm, "rt" ] <> mergeForeigns <> [ "-o", wasmPath, "--all-features" ])
      FS.unlink appPath
      for_ providers \p -> when p.assembled (maybe (pure unit) FS.unlink p.wasm)
      if args.text then do
        let watPath = Path.concat [ bundleDir, "index.wat" ]
        execFile wasmDisBin [ wasmPath, "-o", watPath, "--all-features" ]
        FS.unlink wasmPath
        Console.log (Fmt.fmt @"Wrote {file}" { file: watPath })
      else do
        when (not (Array.null jsProvided)) (emitLoader bundleDir args.input jsProvided (foreignSigs externs))
        Console.log (Fmt.fmt @"Wrote {file}" { file: wasmPath })
  where
  -- Resolved against the current working directory (run `bin` from the repo root).
  runtimeWasm = "runtime/runtime.wasm"
  wasmMergeBin = "binaryen/node_modules/binaryen/bin/wasm-merge"
  wasmDisBin = "binaryen/node_modules/binaryen/bin/wasm-dis"
  wasmAsBin = "binaryen/node_modules/binaryen/bin/wasm-as"

  -- The foreign provider for a module (ADR 0014): a `foreign.wasm` (used directly)
  -- or `foreign.wat` (assembled to a temp `.wasm` in the bundle) is the in-wasm
  -- provider that gets merged; otherwise `wasm` is `Nothing` and it falls back to
  -- the JS loader.
  resolveForeign input bundleDir m = do
    let wasmSrc = Path.concat [ input, m, "foreign.wasm" ]
    hasWasm <- exists wasmSrc
    if hasWasm then pure { name: m, wasm: Just wasmSrc, assembled: false }
    else do
      let watSrc = Path.concat [ input, m, "foreign.wat" ]
      hasWat <- exists watSrc
      if hasWat then do
        let out = Path.concat [ bundleDir, m <> ".foreign.wasm" ]
        execFile wasmAsBin [ watSrc, "-o", out, "--all-features" ]
        pure { name: m, wasm: Just out, assembled: true }
      else pure { name: m, wasm: Nothing, assembled: false }
    where
    exists p = isNothing <$> FS.access p

-- | Emit the JS loader for a program that has host imports (ADR 0014): copy each
-- | used module's `foreign.js` into `<bundle>/foreign/<Module>.js`, then write a
-- | generic `index.mjs` that instantiates `index.wasm`, discovers its imports at
-- | run time, and satisfies each from the matching foreign module's JS.
emitLoader :: FilePath -> FilePath -> Array String -> Object ForeignImport -> Aff Unit
emitLoader bundleDir input mods sigs = do
  let foreignDir = Path.concat [ bundleDir, "foreign" ]
  FS.mkdir' foreignDir { recursive: true, mode: permsAll }
  for_ mods \m -> do
    src <- FS.readTextFile UTF8 (Path.concat [ input, m, "foreign.js" ])
    FS.writeTextFile UTF8 (Path.concat [ foreignDir, m <> ".js" ]) src
  FS.writeTextFile UTF8 (Path.concat [ bundleDir, "index.mjs" ]) (loaderSource (manifestJs mods sigs))
  Console.log (Fmt.fmt @"Wrote {file} (+ {n} foreign module(s))" { file: Path.concat [ bundleDir, "index.mjs" ], n: Array.length mods })

-- | The marshalling manifest as a JSON object literal, keyed by import name
-- | `Module.base`: `{ "M.f": { "params": [<kind>…], "result": <kind> } }` (ADR 0014).
-- | Each `<kind>` is an `encodeMarshalKind` value (`"i"`/`"s"` leaves, `{"a":…}`
-- | array, `{"r":{…}}` record). Restricted to the foreign modules actually linked.
manifestJs :: Array String -> Object ForeignImport -> String
manifestJs mods sigs =
  foreignManifestJson (Array.filter (\s -> Array.elem s.moduleName mods) (Object.values sigs))

-- | The generated loader (ADR 0014): instantiate the GC wasm, discover its host
-- | imports, satisfy each from `./foreign/<Module>.js`, and wrap String-typed
-- | params/results with `$Str` ↔ JS-string marshalling (the baked `MANIFEST` says
-- | which positions are strings; conversions go through the runtime's exported
-- | `strLen`/`strByteAt`/`strNew`/`strSetByte`).
loaderSource :: String -> String
loaderSource manifest =
  """import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MANIFEST = """ <> manifest <>
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
// `k` is a parsed encodeMarshalKind value: a string leaf ("i"/"f"/"s"/"o"), {a:k}
// (array), or {r:{field:k}} (record). eqref (a boxed, nested value) → JS, by kind.
const eqrefToJs = (k, ref) => {
  if (typeof k === "string") {
    if (k === "i") return inst.exports.unboxInt(ref);
    if (k === "s") return strToJs(ref);
    return ref;
  }
  if (k.a !== undefined) {
    const n = inst.exports.arrayLen(ref);
    const out = new Array(n);
    for (let i = 0; i < n; i++) out[i] = eqrefToJs(k.a, inst.exports.arrayGet(ref, i));
    return out;
  }
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
    if (k === "s") return strFromJs(val);
    return val;
  }
  if (k.a !== undefined) {
    const ref = inst.exports.arrayNew(val.length);
    for (let i = 0; i < val.length; i++) inst.exports.arraySet(ref, i, eqrefFromJs(k.a, val[i]));
    return ref;
  }
  // record: recSet each field onto an empty record, keyed by interned label id
  let ref = inst.exports.recEmpty();
  for (const name of Object.keys(k.r)) {
    ref = inst.exports.recSet(ref, inst.exports.internStr(strFromJs(name)), eqrefFromJs(k.r[name], val[name]));
  }
  return ref;
};
const isRaw = (k) => k === "i" || k === "f";
const wrap = (fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefToJs(sig.params[i], a)));
  const r = fn(...xs);
  return isRaw(sig.result) ? r : eqrefFromJs(sig.result, r);
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
export const exports = inst.exports;
export default exports;
"""
