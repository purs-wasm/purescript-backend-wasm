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
import PursWasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, debug, exists, execFile, fileSize, info, joinPath, logAndThrow, mkdirP, readDir, readText, unlink, warn, writeBinary, writeText)
import PursWasm.CLI.Lib (resolveLibPath)
import PursWasm.CLI.Effect.Log (br)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Module (entryRoot, printModname)
import PursWasm.CLI.Options.Types (BuildOption, Platform(..))
import PursWasm.CLI.Ulib.Manifest (LockView, Manifest, parseLock, reachedMismatches, readManifest, resolveModuleSet, ulibManifestFile)
import PursWasm.CLI.Ulib.Shadow (loadShadowMap)
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

-- | ADR 0031: warn — never fail — when a *reached* ulib package's resolved version (`spago.lock`)
-- | differs from the version `ulib-manifest.json` supports (those modules then fall back to the
-- | registry foreign, losing standalone). Absent manifest/lock → no-op.
warnUlibVersionDrift :: forall r. Maybe Manifest -> Maybe LockView -> Set.Set String -> Run (LOG + r) Unit
warnUlibVersionDrift mManifest mLock reachable = case mManifest, mLock of
  Just manifest, Just lock ->
    for_ (reachedMismatches manifest lock reachable) \mm ->
      warn
        ( Log.yellow
            ( Fmt.fmt
                @"⚠ ulib: {pkg} is {got}, but ulib supports {want} — those modules fall back to the registry foreign (run `ulib upgrade`, or align the package-set)"
                { pkg: mm.package, got: fromMaybe "?" mm.got, want: mm.want }
            )
        )
  _, _ -> pure unit

buildCmd :: forall r. FilePath -> BuildOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
buildCmd cliRoot args = do
  debug (show args)
  start <- liftEffect nowMsImpl

  info $
    Log.strong (Log.cyan (Fmt.fmt @"purs-wasm {version}" { version: Version.version }))
      <> Log.green (Fmt.fmt @" building {target} for {platform} platform..." { target: if args.text then "wat" else "wasm", platform: Str.toLower $ show args.platform })
  info ""
  info "Selecting modules to pack in..."

  -- Where the ulib lib lives (ADR 0031 §5): `$PURS_WASM_LIB` if set, else `<cliRoot>/../lib` beside
  -- the binary. `build` has no `-L` flag, so the override is always `Nothing` here.
  libPath <- resolveLibPath cliRoot Nothing
  shadows <- loadShadowMap libPath
  -- Each subdirectory of `input` is named by its dotted module name; sort for a deterministic
  -- build (ADR 0009).
  entries <- readDir args.input >>= maybe (logAndThrow (Fmt.fmt @"input directory not found: {dir}" { dir: args.input })) pure
  let named = Array.sort (Array.mapMaybe toModuleName entries)
  -- `Prim` and the other built-in pseudo-modules have an output dir but no `corefn.json` (compiler
  -- intrinsics); skip any module whose CoreFn artifact is absent rather than failing the build.
  allMods <- Array.filterA (\mod -> joinPath [ args.input, printModname mod, "corefn.json" ] >>= exists) named
  let allModNames = Set.fromFoldable (map printModname allMods)
  let roots = map entryRoot (Array.fromFoldable args.entryModules)
  -- ADR 0031: read the ulib manifest + spago.lock once. `shadowSet` (manifest + lock, exact match)
  -- DRIVES resolution. The manifest is read from the lib itself (`$LIB/ulib-manifest.json`, copied in
  -- at install) so the precompiled lib is self-describing — the build needs no ulib source tree
  -- (matters for the `ulib upgrade` user flow).
  mManifest <- readManifest =<< joinPath [ libPath, ulibManifestFile ]
  mLock <- map parseLock <$> readText "spago.lock"
  -- File-level reachability (before the expensive full decode): read each module's import list
  -- cheaply, from the user output (registry) and — for every lib module that has a corefn — from the
  -- lib. `resolveModuleSet` then runs the plan→recompute→materialize fixpoint (ADR 0031 §6): a
  -- shadow's private helper module (absent from the user closure) is *injected* from the lib.
  userImports <- map Map.fromFoldable $ for allMods \mod -> do
    source <- fromMaybe "" <$> (readText =<< joinPath [ args.input, printModname mod, "corefn.json" ])
    pure (Tuple (printModname mod) (corefnImportsImpl source))
  libImports <- map (Map.fromFoldable <<< Array.catMaybes) $ for (Map.toUnfoldable shadows) \(Tuple name sh) ->
    map (\src -> Tuple name (corefnImportsImpl src)) <$> readText sh.corefn
  let { reachable, libSourced } = resolveModuleSet roots allModNames userImports libImports mManifest mLock
  warnUlibVersionDrift mManifest mLock reachable
  -- Keep only modules with an actual corefn source: a user module, or a real lib module. The closure
  -- also reaches intrinsic / pseudo modules (`Wasm.*`, `Prim*`) the lib corefns import — those have no
  -- corefn anywhere (resolved at codegen), so drop them, exactly as the old `allMods` filter did.
  let resolvable n = Set.member n allModNames || Map.member n libImports
  let modNames = Array.sort (Array.filter resolvable (Set.toUnfoldable reachable))
  let injected = Array.filter (\n -> not (Set.member n allModNames)) modNames
  info
    ( Log.green $ Fmt.fmt @"✓ {count} of {total} module(s) are selected{extra}."
        { count: Array.length modNames - Array.length injected
        , total: Array.length allMods
        , extra: if Array.null injected then "" else Fmt.fmt @" (+{k} ulib internal)" { k: Array.length injected }
        }
    ) *> br
  -- Materialize the plan (ADR 0031 §6): a `libSourced` module's corefn comes from the lib, EXCEPT a
  -- foreign-only ulib module (e.g. `Data.Int`) the lib has no corefn for — there the registry corefn
  -- stays (ulib provides only its foreign). A name that resolves to no corefn at all is skipped.
  modules <- map Array.catMaybes $ for modNames \name -> do
    mLibSrc <-
      if Set.member name libSourced then maybe (pure Nothing) readText (Map.lookup name shadows <#> _.corefn)
      else pure Nothing
    mSrc <- case mLibSrc of
      Just s -> pure (Just s)
      Nothing -> readText =<< joinPath [ args.input, name, "corefn.json" ]
    case mSrc of
      Nothing -> pure Nothing
      Just src -> case parseModule src of
        Left err -> logAndThrow (name <> ": " <> err)
        Right m -> pure (Just m)
  -- Fail early on a `wasm-base` incompatible with this backend (ADR 0026) / CoreFn from an
  -- unsupported purs (ADR 0029).
  either logAndThrow pure (checkWasmBaseCompat modules)
  either logAndThrow pure (checkCorefnVersions modules)
  -- Each module's `externs.cbor` carries the top-level type info CoreFn erased (front B); a module
  -- without readable/decodable externs is simply skipped — its constructors fall back to boxed. A
  -- registry module's externs come from the user output (interface-compatible with the shadow, per
  -- `ulib check`); an injected internal module's externs come from the lib (the user has none).
  externs <- map Array.catMaybes $ for modNames \name ->
    if Set.member name allModNames then readExterns =<< joinPath [ args.input, name, "externs.cbor" ]
    else readExterns =<< joinPath [ libPath, name, "externs.cbor" ]
  allSigs <- buildForeignSigs args.input libPath externs modules
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
      providers <- for foreignMods (resolveForeign shadows libPath args.input bundleDir)
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
      br
      info (Fmt.fmt @"✨️ Finished compilation in {secs}s{size}" { secs: toStringWith (fixed 2) ((end - start) / 1000.0), size }) *> br
      info $ Log.strong $ Log.green "✓ Build succeeded!"
