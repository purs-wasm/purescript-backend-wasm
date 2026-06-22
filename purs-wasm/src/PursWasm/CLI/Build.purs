-- | The `build` command: link every reachable module under `input` into one self-contained wasm
-- | (runtime + foreign providers merged) and write it to `output`, emitting a JS loader when there
-- | are host imports or exports needing marshalling. The 9-stage pipeline mirrors the prototype
-- | exactly; only the effects are abstract (`Run`) — `PureScript.Backend.Wasm.CLI.Node` runs it synchronously.
module PursWasm.CLI.Build
  ( buildCmd
  ) where

import Prelude

import Ansi.Codes as Ansi
import Binaryen as B
import Data.Argonaut.Core (toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..), either, hush)
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.Number.Format (fixed, toStringWith)
import Data.Set as Set
import Data.String (joinWith)
import Data.String as Str
import Data.String.Utils (padStart)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Fmt as Fmt
import Foreign.Object as Object
import Partial.Unsafe (unsafeCrashWith)
import PureScript.Backend.Wasm.Codegen (buildLinkGlue)
import PureScript.Backend.Wasm.Compiler (compilePerModule, effectfulForeigns, finishLink, linkModule, mirTrace, moduleInterface, parseModule, printMir)
import PureScript.Backend.Wasm.Externs (ctorFieldReps)
import PureScript.Backend.Wasm.Lower.Collect (labelCollisions)
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..), exportManifestJson)
import PureScript.Backend.Wasm.MiddleEnd (CacheWrite, liftModule, noCache, optimizeIncrementalM)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (decodePmi, encodePmi)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (decodePmo, encodePmo)
import PureScript.CoreFn (toModuleName)
import PursWasm.CLI.Build.Foreign (resolveForeign)
import PureScript.Backend.Wasm.CLI.ForeignSigs (buildForeignSigs)
import PursWasm.CLI.Build.Loader (emitLoader, exportNeedsLoader, rootExportSigs)
import PureScript.Backend.Wasm.CLI.Paths (runtimeWasm, wasmDisBin, wasmMergeBin)
import PureScript.Backend.Wasm.CLI.Compat (checkCorefnVersions, checkWasmBaseCompat, toolchainTag)
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames, corefnImports)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, debug, exists, execFile, execFileInput, fileSize, info, joinPath, logAndThrow, mkdirP, readBinary, readDir, readText, unlink, warn, writeBinary, writeText)
import PureScript.Backend.Wasm.CLI.Effect.Log (br)
import PureScript.Backend.Wasm.CLI.Effect.Log as Log
import PureScript.Backend.Wasm.CLI.Externs (readExterns)
import PureScript.Backend.Wasm.CLI.Lib (resolveLibPath)
import PureScript.Backend.Wasm.CLI.Module (entryRoot, printModname)
import PursWasm.CLI.Options.Types (BuildOption, Platform(..))
import PureScript.Backend.Wasm.CLI.Ulib.Manifest (LockView, Manifest, parseLock, reachedMismatches, readManifest, resolveModuleSet, ulibManifestFile)
import PureScript.Backend.Wasm.CLI.Ulib.Shadow (loadShadowMap)
import PursWasm.CLI.Version as Version
import Run (Run, EFFECT, liftEffect)
import Type.Row (type (+))

-- | A monotonic clock in milliseconds, for the elapsed-time report.
foreign import nowMsImpl :: Effect Number

foreign import stdoutIsTTY :: Boolean

-- | A byte count as a human-readable size (`B` / `KB` / `MB`).
humanSize :: Int -> String
humanSize b
  | b < 1024 = show b <> " B"
  | b < 1048576 = toStringWith (fixed 1) (toNumber b / 1024.0) <> " KB"
  | otherwise = toStringWith (fixed 1) (toNumber b / 1048576.0) <> " MB"

-- | ADR 0039: an informational provenance note — never a gate — when a *reached* ulib-patched
-- | package's resolved version (`spago.lock`) differs from the version `ulib-manifest.json` was
-- | authored against. Under content-based lenient versioning the patch is still applied (a wat-only
-- | patch keeps the registry corefn + ships its foreign; a reimpl patch's interface is guarded by
-- | `ulib check`), so this no longer implies a fall-back — it just surfaces the drift so an
-- | interface/foreign-sig incompatibility points the user at re-running `ulib-tooling install`.
-- | Absent manifest/lock → no-op.
warnUlibVersionDrift :: forall r. Maybe Manifest -> Maybe LockView -> Set.Set String -> Run (LOG + r) Unit
warnUlibVersionDrift mManifest mLock reachable = case mManifest, mLock of
  Just manifest, Just lock ->
    for_ (reachedMismatches manifest lock reachable) \mm ->
      warn
        ( Log.yellow
            ( Fmt.fmt
                @"ⓘ ulib: {pkg} resolved to {got}; the ulib patch was authored against {want}. It is still applied (lenient versioning, ADR 0039) — if you hit a link/runtime error in a patched module, re-run `ulib-tooling install` against your package-set."
                { pkg: mm.package, got: fromMaybe "?" mm.got, want: mm.want }
            )
        )
  _, _ -> pure unit

-- | The common shape the packaging tail consumes, whichever core produced it (whole-program
-- | `finishLink`, in-process per-module `compilePerModule`, or the Phase-C subprocess orchestrator).
type Linked =
  { foreignModules :: Array String
  , cafInit :: Maybe B.Function
  , cafOwner :: B.Module
  , ownerPath :: FilePath
  , ownerMergeName :: String
  , preWritten :: Array (Tuple FilePath String)
  , cleanup :: Array FilePath
  , cacheWrites :: Array CacheWrite
  , crossModuleExports :: Array String
  }

-- | The per-module link metadata a `purwc` worker emits as a `.link.json` sidecar (ADR 0038 Phase
-- | C): what the orchestrator needs to build the link glue, resolve foreigns, and internalise
-- | cross-module exports after `wasm-merge`. Kept out of the `.pmi` (the dependent-facing interface).
type LinkMeta =
  { cafInitExport :: Maybe String
  , foreignModules :: Array String
  , crossModuleExports :: Array String
  }

-- | Parse a `.link.json` sidecar (defensive — a corrupt/absent sidecar is a build error, not a
-- | silent miscompile, surfaced by the caller).
decodeLinkMeta :: String -> Maybe LinkMeta
decodeLinkMeta txt = do
  obj <- toObject =<< hush (jsonParser txt)
  let strs k = fromMaybe [] (Array.mapMaybe toString <$> (toArray =<< Object.lookup k obj))
  pure
    { cafInitExport: toString =<< Object.lookup "cafInitExport" obj
    , foreignModules: strs "foreignModules"
    , crossModuleExports: strs "crossModuleExports"
    }

-- | Order modules so each comes after the modules it imports (within the set). Transcribes
-- | `MiddleEnd.topoImports` over the cheaply-extracted import map, so the orchestrator can compile a
-- | dependency before its dependents (the worker reads each dependency's `.pmi` from `--deps`).
topoBySrcImports
  :: forall a
   . Array { name :: String, imports :: Array String | a }
  -> Array { name :: String, imports :: Array String | a }
topoBySrcImports inputs = Array.mapMaybe (\n -> Map.lookup n byName) ordered.out
  where
  byName = Map.fromFoldable (map (\i -> Tuple i.name i) inputs)
  names = Set.fromFoldable (map _.name inputs)
  depsOf n = case Map.lookup n byName of
    Nothing -> []
    Just i -> Array.filter (\d -> d /= n && Set.member d names) (Array.nub i.imports)
  ordered = Array.foldl visit { seen: Set.empty, out: [] } (map _.name inputs)
  visit acc n
    | Set.member n acc.seen = acc
    | otherwise =
        let
          after = Array.foldl visit (acc { seen = Set.insert n acc.seen }) (depsOf n)
        in
          after { out = Array.snoc after.out n }

-- | ADR 0038 Phase C (C1): drive the `purwc` worker as a subprocess per module (dependency order),
-- | each reading its dependencies' `.pmi` interfaces from the shared `_build` dir, then assemble the
-- | same `Linked` record the in-process per-module core produces — so the existing packaging tail
-- | (foreign resolution, merge, internalise+DCE, loader) is reused unchanged. The link glue and the
-- | cross-module label-collision check are done in-process here (Binaryen + `labelCollisions`).
orchestrateModules
  :: forall r a
   . FilePath
  -> FilePath
  -> BuildOption
  -> FilePath
  -> Array { name :: String, imports :: Array String | a }
  -> Run (FS + PROC + LOG + EFFECT + r) (Either String Linked)
orchestrateModules cliRoot purwcInput args buildDir srcInfos = do
  let ordered = topoBySrcImports srcInfos
  let entryNames = Set.fromFoldable args.entryModules
  mkdirP buildDir
  purwcPath <- joinPath [ cliRoot, "purwc", "index.dev.js" ]
  -- Drive ONE long-lived `purwc compile-batch` over the whole topo-ordered work-list (each module
  -- `*`-prefixed if it is the program entry), streamed on stdin. One process compiles every module in
  -- order, so the dominant per-spawn cost (Binaryen.js init ~1.3 s) is paid once for the batch, not
  -- per module (ADR 0038 Phase C2). Topo order keeps each dependency's `.pmi` on disk before a
  -- dependent reads it from `--deps` (= the shared `_build`).
  info (Log.cyan (Fmt.fmt @" >  compiling {n} module(s) (purwc batch)" { n: Array.length ordered }))
  let
    workList = joinWith "\n" $ ordered <#> \m ->
      (if Set.member m.name entryNames then "*" else "") <> m.name
  execFileInput "node"
    ( [ purwcPath, "compile-batch", "-I", purwcInput, "--deps", buildDir, "-O", buildDir ]
        <> (if args.debug then [ "-g" ] else [])
        <> (if args.noOpt then [ "--no-opt" ] else [])
    )
    workList
  metas <- for ordered \m -> do
    mTxt <- readText =<< joinPath [ buildDir, m.name <> ".link.json" ]
    case mTxt >>= decodeLinkMeta of
      Just lm -> pure { name: m.name, meta: lm }
      Nothing -> logAndThrow ("orchestrate: missing/corrupt link metadata for " <> m.name)
  pmis <- for ordered \m -> do
    mb <- readBinary =<< joinPath [ buildDir, m.name <> ".pmi" ]
    case mb >>= (hush <<< decodePmi) of
      Just e -> pure e
      Nothing -> logAndThrow ("orchestrate: missing/corrupt .pmi for " <> m.name)
  -- Cross-module label-collision check (the worker dropped the whole-program check in M2b; the
  -- orchestrator runs it over the union of every module's `.pmi` labels, before the merge).
  let allLabels = Object.fromFoldable (pmis >>= \e -> (Object.toUnfoldable e.labels :: Array (Tuple String Int)))
  case Array.head (labelCollisions allLabels) of
    Just clash -> pure (Left ("label hash collision across modules: " <> joinWith ", " clash))
    Nothing -> do
      glue <- liftEffect
        (buildLinkGlue (Array.mapMaybe (\m -> (\e -> { moduleName: m.name, cafInitExport: e }) <$> m.meta.cafInitExport) metas))
      gluePath <- joinPath [ buildDir, "link.glue.wasm" ]
      preWritten <- for ordered \m -> do
        p <- joinPath [ buildDir, m.name <> ".wasm" ]
        pure (Tuple p m.name)
      pure
        ( Right
            { foreignModules: Array.nub (metas >>= _.meta.foreignModules)
            , cafInit: glue.cafInit
            , cafOwner: glue.mod
            , ownerPath: gluePath
            , ownerMergeName: "link"
            , preWritten
            , cleanup: ([] :: Array FilePath)
            , cacheWrites: ([] :: Array CacheWrite)
            , crossModuleExports: Array.nub (metas >>= _.meta.crossModuleExports)
            }
        )

-- | Stage every selected module's resolved `corefn.json` (lib-shadowed or registry) + its
-- | `externs.cbor` (a registry/user module's from the user output, a lib-internal module's from the
-- | lib) + the user `cache-db.json`, into one directory — so the `purwc` worker finds ALL modules
-- | under a single `-I`, including ulib-shadowed modules whose corefn lives in the lib, not the user
-- | output (ADR 0038 Phase C2). Keeps `purwc` a pure worker: the ulib resolution stays in the
-- | orchestrator; the worker just reads a uniform input directory.
stageOrchestrateInput
  :: forall r a
   . FilePath
  -> FilePath
  -> FilePath
  -> Set.Set String
  -> Array { name :: String, src :: String | a }
  -> Run (FS + EFFECT + r) Unit
stageOrchestrateInput stageDir userInput libPath allModNames srcInfos = do
  mkdirP stageDir
  for_ srcInfos \i -> do
    mdir <- joinPath [ stageDir, i.name ]
    mkdirP mdir
    cfPath <- joinPath [ mdir, "corefn.json" ]
    writeText cfPath i.src
    exSrc <- joinPath [ if Set.member i.name allModNames then userInput else libPath, i.name, "externs.cbor" ]
    mEx <- readBinary exSrc
    exDst <- joinPath [ mdir, "externs.cbor" ]
    maybe (pure unit) (writeBinary exDst) mEx
  -- the user `cache-db.json` (ADR 0016 private-foreign reconstruction); absent for many projects.
  mDb <- readText =<< joinPath [ userInput, "cache-db.json" ]
  dbDst <- joinPath [ stageDir, "cache-db.json" ]
  maybe (pure unit) (writeText dbDst) mDb

buildCmd :: forall r. FilePath -> FilePath -> BuildOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
buildCmd cliRoot binaryenBinDir args = do
  debug (show args)
  start <- liftEffect nowMsImpl

  info $
    Log.strong (Log.cyan (Fmt.fmt @"purs-wasm {version}" { version: Version.version }))
      <> Log.green (Fmt.fmt @" building {target} for {platform} platform..." { target: if args.text then "wat" else "wasm", platform: Str.toLower $ show args.platform })
  info ""
  info "Selecting modules to pack in..."

  -- Where the ulib lib lives (ADR 0031 §5): `$PURS_WASM_LIB` if set, else `<cliRoot>/lib` shipped in
  -- the package. `build` has no `-L` flag, so the override is always `Nothing` here.
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
  -- ADR 0039: the manifest is now **provenance** (which packages ulib patches + the authored
  -- version), not a resolution gate — resolution is presence-driven (below). Read from the lib itself
  -- (`$LIB/ulib-manifest.json`, copied in at install) so the precompiled lib is self-describing, and
  -- with `spago.lock` it feeds only the informational version-drift note (`warnUlibVersionDrift`).
  mManifest <- readManifest =<< joinPath [ libPath, ulibManifestFile ]
  mLock <- map parseLock <$> readText "spago.lock"
  -- File-level reachability (before the expensive full decode): read each module's import list
  -- cheaply, from the user output (registry) and — for every lib module that has a corefn — from the
  -- lib. `resolveModuleSet` then runs the plan→recompute→materialize fixpoint (ADR 0039): a module is
  -- lib-sourced iff the lib ships a corefn for it (a PureScript-reimplementation patch or its injected
  -- private helper); a wat-only patch keeps the registry corefn (real imports intact) and is NOT
  -- lib-sourced — only its foreign comes from the lib.
  userImports <- map Map.fromFoldable $ for allMods \mod -> do
    source <- fromMaybe "" <$> (readText =<< joinPath [ args.input, printModname mod, "corefn.json" ])
    pure (Tuple (printModname mod) (corefnImports source))
  libImports <- map (Map.fromFoldable <<< Array.catMaybes) $ for (Map.toUnfoldable shadows) \(Tuple name sh) ->
    map (\src -> Tuple name (corefnImports src)) <$> readText sh.corefn
  let { reachable, libSourced } = resolveModuleSet roots userImports libImports
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
    )
  -- ADR 0038 Phase C: the subprocess orchestrator stages every module's corefn into one `-I` for the
  -- worker (incl. ulib-shadowed modules, whose corefn is in the lib). It has no in-process optimized
  -- MIR, so `--dump-mir` is unsupported.
  when (args.orchestrate && isJust args.dumpMir) (logAndThrow "--orchestrate does not support --dump-mir.")
  -- Materialize the plan (ADR 0039): a `libSourced` module's corefn comes from the lib (it is a
  -- reimpl patch or an injected helper — both guaranteed to have a lib corefn now that wat-only
  -- patches are never lib-sourced). Every other reached module's corefn comes from the user output
  -- (registry), with its real imports intact. A name that resolves to no corefn at all is skipped.
  -- Read each module's corefn source and the cheap metadata derived from it WITHOUT a full decode
  -- (ADR 0034): the source hash (the cache key's source input), the import names (for dependency
  -- order), and the foreign-import names (lowering's opaque-import fallback + foreign-sig
  -- resolution). A registry module's corefn comes from the lib (ADR 0031 §6); a name resolving to no
  -- corefn is skipped. The corefn is *decoded* later only for modules the cache cannot reuse.
  srcInfos <- map Array.catMaybes $ for modNames \name -> do
    mLibSrc <-
      if Set.member name libSourced then maybe (pure Nothing) readText (Map.lookup name shadows <#> _.corefn)
      else pure Nothing
    mSrc <- case mLibSrc of
      Just s -> pure (Just s)
      Nothing -> readText =<< joinPath [ args.input, name, "corefn.json" ]
    pure $ mSrc <#> \src ->
      { name
      , mn: Str.split (Str.Pattern ".") name
      , src
      -- ADR 0040: fold the `.pmi`-affecting toolchain axes into the source hash so the cache key is
      -- toolchain-aware (a backend/CoreFn bump invalidates stale artifacts) without threading a new
      -- parameter through the optimizer. `toolchainTag` is shared with the `purwc` worker so their
      -- keys agree (the `diffPurwc` byte-parity contract).
      , sourceHash: hashString (toolchainTag <> "\n" <> src)
      , imports: corefnImports src
      , foreignNames: corefnForeignNames src
      }
  let sourceHashes = Map.fromFoldable (map (\i -> Tuple i.name i.sourceHash) srcInfos)
  -- Each module's `externs.cbor` carries the top-level type info CoreFn erased (front B); a module
  -- without readable/decodable externs is simply skipped — its constructors fall back to boxed. A
  -- registry module's externs come from the user output (interface-compatible with the shadow, per
  -- `ulib check`); an injected internal module's externs come from the lib (the user has none).
  externs <- map Array.catMaybes $ for modNames \name ->
    if Set.member name allModNames then readExterns =<< joinPath [ args.input, name, "externs.cbor" ]
    else readExterns =<< joinPath [ libPath, name, "externs.cbor" ]
  allSigs <- buildForeignSigs args.input libPath externs (map (\i -> { name: i.mn, foreignNames: i.foreignNames }) srcInfos)
  -- `-E/--executable`: produce a runnable that auto-runs the entry's `main`. v0.1 supports this for
  -- node/browser only (the JS loader calls `main` on load); `main` must be `main :: Effect Unit` (a
  -- nullary `Effect`). Validate up front so the build fails before the expensive compile/merge.
  when args.executable do
    case args.platform of
      Standalone -> logAndThrow "--executable is not supported with --platform=standalone (it has no loader to run `main`). Use --platform=node or browser."
      _ -> pure unit
    case Object.lookup "main" (rootExportSigs roots allSigs) of
      Just s
        | Array.null s.params
        , MEffect _ <- s.result -> pure unit
      Just _ -> logAndThrow "--executable requires the entry module's `main` to have type `Effect Unit`."
      Nothing -> logAndThrow "--executable: no `main` export found in the entry module(s)."
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt, perModuleRep: args.perModuleRep }
  -- One bundle per build, written flat under `--output` (no per-module subdir): the build emits a
  -- single linked wasm + optional loader, not per-module artifacts (ADR 0009), so a module-named
  -- directory would be misleading.
  let bundleDir = args.outDir
  mkdirP bundleDir
  -- Incremental cache (ADR 0034), on by default: reuse unchanged modules from `<output>/_build`,
  -- decoding only the modules the cache cannot reuse. Active whenever MIR is optimized; `--no-opt`
  -- (no optimized MIR to cache) takes the whole-program path. `-f/--force` keeps the cache machinery
  -- on (so it is refreshed) but ignores the existing entries — a clean rebuild from scratch.
  -- `--dump-mir` does NOT disable the cache: on a cached build the target's optimized MIR is
  -- pretty-printed straight from its `.pmo` after linking (below).
  let useCache = opts.optimizeMir
  cacheDir <- joinPath [ args.outDir, "_build" ]
  -- The qualified CoreFn-declared foreign names for lowering's opaque-import fallback (ADR 0016),
  -- from the cheap extraction — available for every module without decoding.
  let foreignNames = Set.fromFoldable (srcInfos >>= \i -> map (\base -> i.name <> "." <> base) i.foreignNames)
  -- The generated module imports the shared runtime (`$rt.*`, ADR 0010). Compile it, then merge
  -- `runtime.wasm` + foreign providers with `wasm-merge` into one self-contained wasm.
  appPath <- joinPath [ bundleDir, "app.wasm" ]
  wasmPath <- joinPath [ bundleDir, "index.wasm" ]
  -- Normalise the whole-program `CompiledModule` (one live module emitted to `app.wasm`) to the
  -- common `Linked` shape the packaging below consumes.
  let
    wholeLinked b =
      { foreignModules: b.foreignModules
      , cafInit: b.cafInit
      , cafOwner: b.mod
      , ownerPath: appPath
      , ownerMergeName: "app"
      , preWritten: ([] :: Array (Tuple FilePath String))
      , cleanup: [ appPath ]
      , cacheWrites: b.cacheWrites
      , crossModuleExports: ([] :: Array String)
      }
  -- The lower+codegen core (ADR 0037): whole-program `finishLink` (the oracle, one wasm) or, under
  -- `--per-module-codegen`, `compilePerModule` — each module is codegenned to its own wasm written
  -- under `_build/<module>.wasm` (alongside the .pmi/.pmo cache, ready for Phase-3 reuse) and the
  -- link glue is the `cafOwner`. Both normalise to `Linked`, so the packaging (foreign resolution,
  -- loader, merge, footer) below is shared; the differential harness checks behaviour parity.
  let
    compileLinked modules cacheWrites =
      if args.perModuleCodegen then do
        result <- liftEffect (compilePerModule opts roots allSigs foreignNames externs modules)
        case result of
          Left err -> pure (Left err)
          Right arts -> do
            mkdirP cacheDir
            preWritten <- for arts.moduleBytes \mb -> do
              p <- joinPath [ cacheDir, mb.moduleName <> ".wasm" ]
              writeBinary p mb.bytes
              pure (Tuple p mb.moduleName)
            gluePath <- joinPath [ cacheDir, "link.glue.wasm" ]
            pure
              ( Right
                  { foreignModules: arts.foreignModules
                  , cafInit: arts.cafInit
                  , cafOwner: arts.glue
                  , ownerPath: gluePath
                  , ownerMergeName: "link"
                  , preWritten
                  , cleanup: ([] :: Array FilePath) -- keep per-module wasms in _build (Phase-3 cache)
                  , cacheWrites
                  , crossModuleExports: arts.crossModuleExports
                  }
              )
      else do
        built <- liftEffect (finishLink opts roots allSigs foreignNames externs modules cacheWrites)
        pure (map wholeLinked built)
  stageDir <- joinPath [ cacheDir, "stage" ]
  when args.orchestrate (stageOrchestrateInput stageDir args.input libPath allModNames srcInfos)
  linkResult <-
    if args.orchestrate then orchestrateModules cliRoot stageDir args cacheDir srcInfos
    else if useCache then do
      -- Load each module's cache interface (.pmi) + object (.pmo); cached iff both load. `--force`
      -- starts from an empty cache, so every module is a miss and the cache is rewritten fresh.
      cachedMap <-
        if args.force then pure Map.empty
        else map (Map.fromFoldable <<< Array.catMaybes) $ for srcInfos \i -> do
          pmiPath <- joinPath [ cacheDir, i.name <> ".pmi" ]
          pmoPath <- joinPath [ cacheDir, i.name <> ".pmo" ]
          mPmi <- readBinary pmiPath
          mPmo <- readBinary pmoPath
          pure do
            pmi <- hush <<< decodePmi =<< mPmi
            finalMod <- hush <<< decodePmo =<< mPmo
            pure (Tuple i.name { sourceHash: pmi.sourceHash, key: pmi.key, deps: pmi.deps, summary: pmi.summary, finalMod })
      -- Coarse decode-skip pre-pass (ADR 0034): a module need not be decoded at all iff its source
      -- AND every transitive dependency's source are unchanged (a guaranteed cache hit). The precise
      -- per-module key inside the optimizer still decides reuse for the modules that are decoded.
      let
        ownUnchanged name = case Map.lookup name cachedMap of
          Just c -> Map.lookup name sourceHashes == Just c.sourceHash
          Nothing -> false
        cachedDeps name = maybe [] _.deps (Map.lookup name cachedMap)
        shrink s =
          let
            s' = Set.filter (\n -> Array.all (\d -> Set.member d s) (cachedDeps n)) s
          in
            if Set.size s' == Set.size s then s else shrink s'
        skippable = shrink (Set.filter ownUnchanged (Set.fromFoldable (map _.name srcInfos)))
      info (Fmt.fmt @"Compiling {count} module(s) ({cached} cached)…" { count: Array.length srcInfos, cached: Set.size skippable })
      -- Decode (and version-check) only the modules that are not guaranteed hits.
      decoded <- map (Map.fromFoldable <<< Array.catMaybes) $ for srcInfos \i ->
        if Set.member i.name skippable then pure Nothing
        else case parseModule i.src of
          Left err -> logAndThrow (i.name <> ": " <> err)
          Right m -> pure (Just (Tuple i.name m))
      let decodedModules = Array.fromFoldable (Map.values decoded)
      either logAndThrow pure (checkWasmBaseCompat Version.version decodedModules)
      either logAndThrow pure (checkCorefnVersions decodedModules)
      let
        inputs = srcInfos <#> \i ->
          { name: i.name
          , imports: i.imports
          , sourceHash: i.sourceHash
          , cached: Map.lookup i.name cachedMap <#> \c -> { key: c.key, deps: c.deps, summary: c.summary, finalMod: c.finalMod }
          , lift: case Map.lookup i.name decoded of
              Just m -> \_ -> liftModule m
              Nothing -> \_ -> unsafeCrashWith ("internal: cache hit forced lift for " <> i.name)
          }
      -- Drive the dependency-ordered optimizer here (not inside `Compiler`), so each module's
      -- progress can be reported live (ADR 0034). A cache hit advances the counter quietly; a miss
      -- names the module it is compiling. The optimizer's per-module work is forced strictly per
      -- step, so the counter keeps pace with the actual compilation.
      let eff = effectfulForeigns allSigs
      optimized <- optimizeIncrementalM
        ( \p ->
            if p.hit then do
              Log.debug $ Fmt.fmt @"{name} is already optmized. Skip." { name: p.name }
            else do
              when stdoutIsTTY do
                Log.info $ Ansi.escapeCodeToString (Ansi.PreviousLine 2)
                Log.info $ Ansi.escapeCodeToString (Ansi.EraseLine Ansi.Entire)
                Log.info $ Ansi.escapeCodeToString (Ansi.PreviousLine 2)
              Log.info $ Log.cyan $ Fmt.fmt @" >  [{i} of {n}] Compling {name}"
                { i: padStart (Str.length $ show p.total) (show p.index)
                , n: p.total
                , name: p.name
                }
        )
        eff.names
        eff.arities
        inputs
      -- liftEffect progressEndImpl
      br *> info (Log.blue "Linking (lower + codegen)…")
      compileLinked optimized.modules optimized.writes
    else case args.dumpMir of
      -- `--dump-mir` needs the whole CoreFn for the trace, so keep the decode-everything path
      -- (a debugging build, where peak memory is not a concern).
      Just target -> do
        info (Fmt.fmt @"Compiling {count} module(s)…" { count: Array.length srcInfos })
        decodedModules <- map Array.catMaybes $ for srcInfos \i -> case parseModule i.src of
          Left err -> logAndThrow (i.name <> ": " <> err)
          Right m -> pure (Just m)
        either logAndThrow pure (checkWasmBaseCompat Version.version decodedModules)
        either logAndThrow pure (checkCorefnVersions decodedModules)
        mirPath <- joinPath [ bundleDir, target <> ".mir.txt" ]
        writeText mirPath (mirTrace opts decodedModules allSigs target)
        info $ Log.blue ("✓ Wrote MIR trace for " <> target <> " to " <> mirPath)
        -- `--dump-mir` is a whole-program debug path; per-module codegen is not applied here.
        liftEffect (linkModule opts roots decodedModules externs allSigs noCache) <#> map wholeLinked
      -- Cold / `--no-opt`: translate + lambda-lift each module and drop its CoreFn before the next,
      -- so the whole program is never resident as CoreFn *and* MIR at once (copy-reduction — the
      -- front-half memory floor that blocks self-compilation). `--no-opt` does no whole-program
      -- optimization, so per-module `liftModule` is the full middle-end; reuse the precomputed
      -- `foreignNames` and call `finishLink` directly, exactly as the cached path above does.
      Nothing -> do
        info (Fmt.fmt @"Compiling {count} module(s)…" { count: Array.length srcInfos })
        either logAndThrow pure
          (checkWasmBaseCompat Version.version (map (\i -> { name: i.mn, foreignNames: i.foreignNames }) srcInfos))
        lifted <- map Array.catMaybes $ for srcInfos \i -> case parseModule i.src of
          Left err -> logAndThrow (i.name <> ": " <> err)
          Right m -> do
            either logAndThrow pure (checkCorefnVersions [ m ])
            pure (Just (liftModule m))
        compileLinked lifted []
  case linkResult of
    Left err -> logAndThrow err
    Right l -> do
      -- Persist cache misses (ADR 0034) before the merge, so a later failure still leaves a usable
      -- cache. `cacheWrites` is empty unless this was a `--cache` build.
      when (not (Array.null l.cacheWrites)) do
        mkdirP cacheDir
        for_ l.cacheWrites \w -> do
          pmiPath <- joinPath [ cacheDir, w.name <> ".pmi" ]
          pmoPath <- joinPath [ cacheDir, w.name <> ".pmo" ]
          -- The lowering interface (ADR 0038 Phase B): derive this module's signature tables from
          -- its finalized MIR + its own foreigns, so the `.pmi` is the complete interface.
          let mForeignNames = maybe [] (\i -> map (\b -> w.name <> "." <> b) i.foreignNames) (Array.find (\i -> i.name == w.name) srcInfos)
          let iface = moduleInterface (ctorFieldReps externs) allSigs mForeignNames w.entry.finalMod
          writeBinary pmiPath
            ( encodePmi
                { sourceHash: w.sourceHash
                , key: w.entry.key
                , deps: w.deps
                , summary: w.entry.summary
                , funcs: iface.funcs
                , ctors: iface.ctors
                , dictCtors: iface.dictCtors
                , enumCtors: iface.enumCtors
                , foreignSigs: iface.foreignSigs
                , foreignNames: iface.foreignNames
                , labels: iface.labels
                }
            )
          writeBinary pmoPath (encodePmo w.entry.finalMod)
      -- `--dump-mir` on a cached build: the optimized MIR is in the target's `.pmo` (just written
      -- if it was a miss, otherwise the unchanged hit), so pretty-print that — no re-optimize, no
      -- cache disable. (`--no-opt` has no `.pmo`; it took the whole-program `mirTrace` path above.)
      case args.dumpMir of
        Just target | useCache -> do
          mirPath <- joinPath [ bundleDir, target <> ".mir.txt" ]
          pmoPath <- joinPath [ cacheDir, target <> ".pmo" ]
          readBinary pmoPath >>= case _ of
            Just bytes -> case decodePmo bytes of
              Right m -> writeText mirPath (printMir m) *> info (Log.blue ("✓ Wrote MIR for " <> target <> " to " <> mirPath))
              Left e -> warn (Log.yellow ("--dump-mir: could not decode " <> target <> ".pmo: " <> e))
            Nothing -> warn (Log.yellow ("--dump-mir: no cached .pmo for " <> target <> " (is it in the reachable set?)"))
        _ -> pure unit
      -- Resolve each foreign module along the ADR 0014 ladder; a `foreign.wasm`/`.wat` provider is
      -- merged (speaks the internal ABI), else it falls back to the JS loader. `foreignModules` is
      -- the precise set the codegen emitted imports for (no byte re-parse).
      providers <- for l.foreignModules (resolveForeign binaryenBinDir shadows libPath args.input bundleDir)
      let wasmProvided = Array.mapMaybe (\p -> Tuple p.name <$> p.wasm) providers
      let jsProvided = Array.mapMaybe (\p -> if isNothing p.wasm then Just p.name else Nothing) providers
      -- Policy on foreign imports with no `foreign.wat` provider (they otherwise fall back to a
      -- `foreign.js` the loader copies). `standalone` has no loader, so any such foreign is fatal;
      -- `--no-js-fallback` makes it fatal for node/browser too.
      when (not (Array.null jsProvided)) case args.platform of
        Standalone -> logAndThrow (Fmt.fmt @"--platform=standalone needs every foreign import provided as wasm, but {n} fall back to JS: {names}" { n: Array.length jsProvided, names: joinWith ", " jsProvided })
        _ -> when args.noJsFallback (logAndThrow (Fmt.fmt @"--no-js-fallback set, but {n} foreign import(s) lack a foreign.wat provider: {names}" { n: Array.length jsProvided, names: joinWith ", " jsProvided }))
      let exportSigs = rootExportSigs roots allSigs
      -- `-E` forces a loader (it must call `main` on load) even if nothing else needs marshalling.
      let needLoader = args.executable || not (Array.null jsProvided) || Array.any exportNeedsLoader (Object.values exportSigs)
      -- Packaging decides how CAF init runs (ADR 0006 / 0021): when a loader is emitted
      -- (node/browser + needLoader) it calls `$caf_init` AFTER instantiation, so a CAF whose init
      -- routes through a re-entrant JS foreign reaches the bound instance; with no loader, set it as
      -- the wasm `start` section (safe — a no-loader build has no JS foreign to re-enter). Then emit
      -- and dispose the live module (the "emit" half of the link/emit split).
      let loaderEmitted = args.platform /= Standalone && needLoader
      bytes <- liftEffect do
        when (not loaderEmitted) (maybe (pure unit) (B.setStart l.cafOwner) l.cafInit)
        b <- B.emitBinary l.cafOwner
        B.dispose l.cafOwner
        pure b
      writeBinary l.ownerPath bytes
      let mergeForeigns = wasmProvided >>= \(Tuple name wp) -> [ wp, name ]
      -- merge inputs: the owner (whole-program `app`, or the per-module link glue) + any already-
      -- written per-module wasms (each named by its dotted module name, matching the cross-module
      -- import module fields) + the runtime + foreign providers, into one self-contained wasm.
      let appMerges = [ l.ownerPath, l.ownerMergeName ] <> (l.preWritten >>= \(Tuple p n) -> [ p, n ])
      info (Fmt.fmt @"Linking runtime + {n} foreign provider(s) with wasm-merge…\n" { n: Array.length wasmProvided })
      execFile (wasmMergeBin binaryenBinDir) (appMerges <> [ runtimeWasm cliRoot, "rt" ] <> mergeForeigns <> [ "-o", wasmPath, "--all-features" ])
      for_ l.cleanup unlink
      for_ providers \p -> when p.assembled (maybe (pure unit) unlink p.wasm)
      -- Each per-module wasm is already optimised independently (ADR 0037 Phase 3 — verified to keep
      -- GC types canonical under merge), so the merged wasm needs no whole-program re-optimise. Post
      -- merge, internalise the cross-module function exports (now resolved — they only existed for
      -- `wasm-merge`; the oracle never exported dependency-module functions) and run a cheap DCE pass
      -- (`remove-unused-module-elements`) to drop the now-unreachable, matching the oracle's surface.
      -- The whole-program path already optimised before merge, so this is per-module only.
      when ((args.perModuleCodegen || args.orchestrate) && opts.optimize) do
        info (Log.blue "Internalizing cross-module exports + DCE…")
        readBinary wasmPath >>= case _ of
          Nothing -> logAndThrow ("merged wasm not found: " <> wasmPath)
          Just merged -> do
            optimized <- liftEffect do
              mod <- B.readBinary merged
              -- `readBinary` defaults to MVP features; the merged module is wasm-GC, so re-enable
              -- GC before emitting or the GC type/supertype encoding is written invalid.
              B.setFeaturesGC mod
              for_ l.crossModuleExports (B.removeExport mod)
              B.runPasses mod [ "remove-unused-module-elements" ]
              out <- B.emitBinary mod
              B.dispose mod
              pure out
            writeBinary wasmPath optimized
      artifact <-
        if args.text then do
          watPath <- joinPath [ bundleDir, "index.wat" ]
          execFile (wasmDisBin binaryenBinDir) [ wasmPath, "-o", watPath, "--all-features" ]
          unlink wasmPath
          info $ Log.blue (Fmt.fmt @"✓ Wrote {file}" { file: watPath })
          pure watPath
        else do
          -- emit the JS loader (it satisfies JS foreigns, marshals non-scalar exports, and runs
          -- `$caf_init` + `main`) when needed — ADR 0014. `standalone` is a self-contained wasm with
          -- no loader; node/browser emit one when needed. node and browser share the same loader
          -- except for how it loads the wasm bytes (Node reads the file; the browser `fetch`es it).
          -- Browser emits a single wasm — chunking, which `--no-chunks` opts out of, is not yet done.
          let emit browser = emitLoader cliRoot browser args.executable bundleDir args.input jsProvided allSigs (exportManifestJson exportSigs)
          case args.platform of
            Standalone -> pure unit
            Browser -> when needLoader (emit true)
            Node -> when needLoader (emit false)
          info $ Log.blue (Fmt.fmt @"✓ Wrote {file}" { file: wasmPath })
          pure wasmPath
      -- footer: elapsed wall-clock time and the artifact's size
      end <- liftEffect nowMsImpl
      size <- maybe "" (\b -> ", " <> humanSize b) <$> fileSize artifact
      br
      info (Fmt.fmt @"✨️ Finished compilation in {secs}s{size}" { secs: toStringWith (fixed 2) ((end - start) / 1000.0), size }) *> br
      info $ Log.strong $ Log.green "✓ Build succeeded!"
