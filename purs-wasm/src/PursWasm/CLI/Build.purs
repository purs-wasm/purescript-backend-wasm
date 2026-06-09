-- | The `build` command: link every reachable module under `input` into one self-contained wasm
-- | (runtime + foreign providers merged) and write it to `output`, emitting a JS loader when there
-- | are host imports or exports needing marshalling. The 9-stage pipeline mirrors the prototype
-- | exactly; only the effects are abstract (`Run`) — `PursWasm.CLI.Node` runs it synchronously.
module PursWasm.CLI.Build
  ( buildCmd
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..), either)
import Data.List.NonEmpty as NEL
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Set as Set
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Fmt as Fmt
import Foreign.Object as Object
import PureScript.Backend.Wasm.Compiler (compileModules, mirTrace, parseModule)
import PureScript.Backend.Wasm.Lower.IR (exportManifestJson)
import PureScript.CoreFn (toModuleName)
import PursWasm.CLI.Build.Foreign (resolveForeign)
import PursWasm.CLI.Build.ForeignSigs (buildForeignSigs)
import PursWasm.CLI.Build.Loader (emitLoader, exportNeedsLoader, rootExportSigs)
import PursWasm.CLI.Build.Paths (runtimeWasm, wasmDisBin, wasmMergeBin)
import PursWasm.CLI.Compat (checkCorefnVersions, checkWasmBaseCompat)
import PursWasm.CLI.Effect (FS, FilePath, LOG, PROC, debug, exists, execFile, info, joinPath, logAndThrow, mkdirP, readDir, readText, resolvePath, unlink, writeBinary, writeText)
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Module (entryRoot, printModname, reachableClosure)
import PursWasm.CLI.Options.Types (BuildOption)
import PursWasm.CLI.Ulib.Shadow (loadShadowMap, shadowOrRegistry)
import Run (Run, EFFECT, liftEffect)
import Type.Row (type (+))

-- | The dotted import module names of a `corefn.json`, extracted cheaply (no full decode), for
-- | file-level reachability pruning.
foreign import corefnImportsImpl :: String -> Array String

-- | The host-import module names a wasm binary declares (the user `foreign import` modules a JS
-- | loader must satisfy; ADR 0014).
foreign import importModulesImpl :: Uint8Array -> Effect (Array String)

buildCmd :: forall r. FilePath -> BuildOption -> Run (FS + PROC + LOG + EFFECT + r) Unit
buildCmd cliRoot args = do
  debug (show args)
  -- ulib lib (ADR 0028) sits beside the compiler (`<cli>/../lib`); `resolvePath` normalises the
  -- `..` to an absolute path. It is an FS-effect op (the interpreter owns `Node.Path`), so this
  -- command logic stays platform-neutral.
  libPath <- resolvePath [ cliRoot, ".." ] "lib"
  shadows <- loadShadowMap libPath
  -- Each subdirectory of `input` is named by its dotted module name; sort for a deterministic
  -- build (ADR 0009).
  entries <- readDir args.input >>= maybe (logAndThrow (Fmt.fmt @"input directory not found: {dir}" { dir: args.input })) pure
  let named = Array.sort (Array.mapMaybe toModuleName entries)
  -- `Prim` and the other built-in pseudo-modules have an output dir but no `corefn.json` (compiler
  -- intrinsics); skip any module whose CoreFn artifact is absent rather than failing the build.
  allMods <- Array.filterA (\mod -> joinPath [ args.input, printModname mod, "corefn.json" ] >>= exists) named
  let roots = map entryRoot (Array.fromFoldable args.entryModules)
  -- File-level reachability pruning (before the expensive full decode): read each module's imports
  -- cheaply, then keep only the modules transitively reachable from the entry roots.
  importPairs <- for allMods \mod -> do
    source <- fromMaybe "" <$> (readText =<< joinPath [ args.input, printModname mod, "corefn.json" ])
    pure (Tuple (printModname mod) (corefnImportsImpl source))
  let reachable = reachableClosure roots (Map.fromFoldable importPairs)
  let mods = Array.filter (\mod -> Set.member (printModname mod) reachable) allMods
  info (Fmt.fmt @"Linking {count} of {total} module(s) from {dir}" { count: Array.length mods, total: Array.length allMods, dir: args.input })
  modules <- for mods \mod -> do
    source <- fromMaybe "" <$> (readText =<< joinPath [ args.input, printModname mod, "corefn.json" ])
    case parseModule source of
      Left err -> logAndThrow (printModname mod <> ": " <> err)
      Right m -> shadowOrRegistry shadows mod m
  -- Fail early on a `wasm-base` incompatible with this backend (ADR 0026) / CoreFn from an
  -- unsupported purs (ADR 0029).
  either logAndThrow pure (checkWasmBaseCompat modules)
  either logAndThrow pure (checkCorefnVersions modules)
  -- Each module's `externs.cbor` carries the top-level type info CoreFn erased (front B); a module
  -- without readable/decodable externs is simply skipped — its constructors fall back to boxed.
  externs <- Array.catMaybes <$> for mods \mod ->
    readExterns =<< joinPath [ args.input, printModname mod, "externs.cbor" ]
  allSigs <- buildForeignSigs args.input externs modules
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt }
  -- `--trace-mir <Module>`: dump that module's MIR after every optimizer sub-stage to
  -- ./mir-trace.txt (debugging the optimizer).
  case args.traceMir of
    Nothing -> pure unit
    Just target -> do
      writeText "mir-trace.txt" (mirTrace opts modules allSigs target)
      info ("Wrote MIR trace for " <> target <> " to ./mir-trace.txt")
  -- one bundle per build, in a dir named after the (first) entry module (mirrors purs / es).
  bundleDir <- joinPath [ args.outDir, NEL.head args.entryModules ]
  mkdirP bundleDir
  -- The generated module imports the shared runtime (`$rt.*`, ADR 0010). Compile it, then merge
  -- `runtime.wasm` + foreign providers with `wasm-merge` into one self-contained wasm.
  appPath <- joinPath [ bundleDir, "app.wasm" ]
  wasmPath <- joinPath [ bundleDir, "index.wasm" ]
  liftEffect (compileModules opts roots modules externs allSigs) >>= case _ of
    Left err -> logAndThrow err
    Right bytes -> do
      -- the user `foreign import` modules the wasm needs (empty for a self-contained program).
      foreignMods <- liftEffect (importModulesImpl bytes)
      writeBinary appPath bytes
      -- Resolve each foreign module along the ADR 0014 ladder; a `foreign.wasm`/`.wat` provider is
      -- merged (speaks the internal ABI), else it falls back to the JS loader.
      providers <- for foreignMods (resolveForeign args.input bundleDir)
      let wasmProvided = Array.mapMaybe (\p -> Tuple p.name <$> p.wasm) providers
      let jsProvided = Array.mapMaybe (\p -> if isNothing p.wasm then Just p.name else Nothing) providers
      let mergeForeigns = wasmProvided >>= \(Tuple name wp) -> [ wp, name ]
      execFile wasmMergeBin ([ appPath, "app", runtimeWasm, "rt" ] <> mergeForeigns <> [ "-o", wasmPath, "--all-features" ])
      unlink appPath
      for_ providers \p -> when p.assembled (maybe (pure unit) unlink p.wasm)
      if args.text then do
        watPath <- joinPath [ bundleDir, "index.wat" ]
        execFile wasmDisBin [ wasmPath, "-o", watPath, "--all-features" ]
        unlink wasmPath
        info (Fmt.fmt @"Wrote {file}" { file: watPath })
      else do
        -- emit the JS loader when there are JS foreign imports to satisfy, or when any entry export
        -- needs marshalling (a non-`i32`/`f64` param/result); ADR 0014.
        let exportSigs = rootExportSigs roots allSigs
        let needLoader = not (Array.null jsProvided) || Array.any exportNeedsLoader (Object.values exportSigs)
        when needLoader (emitLoader bundleDir args.input jsProvided allSigs (exportManifestJson exportSigs))
        info (Fmt.fmt @"Wrote {file}" { file: wasmPath })
