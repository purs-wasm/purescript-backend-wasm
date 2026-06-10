-- | The `build` command: link every reachable module under `input` into one self-contained wasm
-- | (runtime + foreign providers merged) and write it to `output`, emitting a JS loader when there
-- | are host imports or exports needing marshalling. The 9-stage pipeline mirrors the prototype
-- | exactly; only the effects are abstract (`Run`) — `PursWasm.CLI.Node` runs it synchronously.
module PursWasm.CLI.Build
  ( buildCmd
  ) where

import Prelude

import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..), either)
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Number.Format (fixed, toStringWith)
import Data.Set as Set
import Data.String (joinWith)
import Data.String as Str
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
import PursWasm.CLI.Effect (FS, FilePath, LOG, PROC, debug, exists, execFile, fileSize, info, joinPath, logAndThrow, mkdirP, readDir, readText, resolvePath, unlink, writeBinary, writeText)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Module (entryRoot, printModname, reachableClosure)
import PursWasm.CLI.Options.Types (BuildOption, Platform(..))
import PursWasm.CLI.Ulib.Shadow (loadShadowMap, shadowOrRegistry)
import PursWasm.CLI.Version as Version
import Run (Run, EFFECT, liftEffect)
import Type.Row (type (+))

-- | The dotted import module names of a `corefn.json`, extracted cheaply (no full decode), for
-- | file-level reachability pruning.
foreign import corefnImportsImpl :: String -> Array String

-- | The host-import module names a wasm binary declares (the user `foreign import` modules a JS
-- | loader must satisfy; ADR 0014).
foreign import importModulesImpl :: Uint8Array -> Effect (Array String)

-- | A monotonic clock in milliseconds, for the elapsed-time report.
foreign import nowMsImpl :: Effect Number

-- | A byte count as a human-readable size (`B` / `KB` / `MB`).
humanSize :: Int -> String
humanSize b
  | b < 1024 = show b <> " B"
  | b < 1048576 = toStringWith (fixed 1) (toNumber b / 1024.0) <> " KB"
  | otherwise = toStringWith (fixed 1) (toNumber b / 1048576.0) <> " MB"

buildCmd :: forall r. FilePath -> BuildOption -> Run (FS + PROC + LOG + EFFECT + r) Unit
buildCmd cliRoot args = do
  debug (show args)
  start <- liftEffect nowMsImpl

  info $
    Log.strong (Log.cyan (Fmt.fmt @"purs-wasm {version}" { version: Version.version }))
      <> Log.green (Fmt.fmt @" building {target} for {platform} platform...\n" { target: if args.text then "wat" else "wasm", platform: Str.toLower $ show args.platform })
  info "Selecting modules to pack in..."

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
  info $ Log.green (Fmt.fmt @"✓ {count} of {total} module(s) are selected.\n" { count: Array.length mods, total: Array.length allMods })
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
  -- One bundle per build, written flat under `--output` (no per-module subdir): the build emits a
  -- single linked wasm + optional loader, not per-module artifacts (ADR 0009), so a module-named
  -- directory would be misleading.
  let bundleDir = args.outDir
  mkdirP bundleDir
  -- `--dump-mir <Module>`: dump that module's MIR after every optimizer sub-stage to
  -- `<output>/<Module>.mir.txt` (debugging the optimizer; supersedes the old dump-mir/dump-opt
  -- scripts, which only saw the fixtures you hand-linked — this sees the real reachable closure).
  case args.dumpMir of
    Nothing -> pure unit
    Just target -> do
      mirPath <- joinPath [ bundleDir, target <> ".mir.txt" ]
      writeText mirPath (mirTrace opts modules allSigs target)
      info $ Log.blue ("✓ Wrote MIR trace for " <> target <> " to " <> mirPath)
  -- The generated module imports the shared runtime (`$rt.*`, ADR 0010). Compile it, then merge
  -- `runtime.wasm` + foreign providers with `wasm-merge` into one self-contained wasm.
  appPath <- joinPath [ bundleDir, "app.wasm" ]
  wasmPath <- joinPath [ bundleDir, "index.wasm" ]
  info (Fmt.fmt @"Compiling {count} module(s)…" { count: Array.length modules })
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
      -- Policy on foreign imports with no `foreign.wat` provider (they otherwise fall back to a
      -- `foreign.js` the loader copies). `standalone` has no loader, so any such foreign is fatal;
      -- `--no-js-fallback` makes it fatal for node/browser too.
      when (not (Array.null jsProvided)) case args.platform of
        Standalone -> logAndThrow (Fmt.fmt @"--platform=standalone needs every foreign import provided as wasm, but {n} fall back to JS: {names}" { n: Array.length jsProvided, names: joinWith ", " jsProvided })
        _ -> when args.noJsFallback (logAndThrow (Fmt.fmt @"--no-js-fallback set, but {n} foreign import(s) lack a foreign.wat provider: {names}" { n: Array.length jsProvided, names: joinWith ", " jsProvided }))
      let mergeForeigns = wasmProvided >>= \(Tuple name wp) -> [ wp, name ]
      info (Fmt.fmt @"Linking runtime + {n} foreign provider(s) with wasm-merge…\n" { n: Array.length wasmProvided })
      execFile wasmMergeBin ([ appPath, "app", runtimeWasm, "rt" ] <> mergeForeigns <> [ "-o", wasmPath, "--all-features" ])
      unlink appPath
      for_ providers \p -> when p.assembled (maybe (pure unit) unlink p.wasm)
      artifact <-
        if args.text then do
          watPath <- joinPath [ bundleDir, "index.wat" ]
          execFile wasmDisBin [ wasmPath, "-o", watPath, "--all-features" ]
          unlink wasmPath
          info $ Log.blue (Fmt.fmt @"✓ Wrote {file}" { file: watPath })
          pure watPath
        else do
          -- emit the JS loader when there are JS foreign imports to satisfy, or when any entry export
          -- needs marshalling (a non-`i32`/`f64` param/result); ADR 0014.
          let exportSigs = rootExportSigs roots allSigs
          let needLoader = not (Array.null jsProvided) || Array.any exportNeedsLoader (Object.values exportSigs)
          -- `standalone` is a self-contained wasm with no loader; node/browser emit one when needed.
          -- (browser currently emits a single wasm — chunking, which `--no-chunks` opts out of, is not
          -- implemented yet, so browser behaves like node here.)
          case args.platform of
            Standalone -> pure unit
            _ -> when needLoader (emitLoader bundleDir args.input jsProvided allSigs (exportManifestJson exportSigs))
          info $ Log.blue (Fmt.fmt @"✓ Wrote {file}" { file: wasmPath })
          pure wasmPath
      -- footer: elapsed wall-clock time and the artifact's size
      end <- liftEffect nowMsImpl
      size <- maybe "" (\b -> ", " <> humanSize b) <$> fileSize artifact
      info ""
      info (Fmt.fmt @"✨️ Finished compilation in {secs}s{size}\n" { secs: toStringWith (fixed 2) ((end - start) / 1000.0), size })
      info $ Log.strong $ Log.green (Fmt.fmt @"✓ Build succeeded!" { secs: toStringWith (fixed 2) ((end - start) / 1000.0), size })
