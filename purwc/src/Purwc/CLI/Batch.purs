-- | The `compile-batch` command (ADR 0038 Phase C2): a long-lived worker that compiles EVERY module
-- | in a stdin work-list, in order, within ONE process. Each line is a module name, `*`-prefixed if it
-- | is the program entry (host-ABI bare exports); the orchestrator streams the topologically-ordered
-- | list so a dependency is compiled before any dependent reads its interface.
-- |
-- | The point is amortisation AND O(N) scaling. Binaryen.js' Emscripten init (~1.3 s) is paid once for
-- | the process, not per module. Crucially, the batch drives the *incremental* optimizer itself — it
-- | threads the same accumulator (`IncAccum`) the in-process whole-program loop (`optimizeIncrementalM`)
-- | does, seeded from the store-hit `.pmi`s already staged in `--deps`. So each module is optimized
-- | against `accCtx ⊕ its own contribution` exactly ONCE: the dependency summaries are decoded once and
-- | the optimization context is grown by one module per step, rather than re-decoding and re-folding
-- | every accumulated summary per module (the old `purwc compile`-per-module path, which was O(N²) in
-- | the module count — a single-module compile got slower the more modules preceded it). The per-module
-- | output is byte-identical to the whole-program oracle because it runs the very same `incMissStep`.
module Purwc.CLI.Batch
  ( batchCmd
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as Str
import Data.Traversable (for)
import Foreign.Object as Object
import Fmt as Fmt
import PureScript.Backend.Wasm.CLI.Compat (toolchainTag)
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, joinPath, logAndThrow, readBinary, readStdin, readText)
import PureScript.Backend.Wasm.CLI.Externs (readExterns)
import PureScript.Backend.Wasm.CLI.ForeignSigs (buildForeignSigs)
import PureScript.Backend.Wasm.CLI.Lib (resolveLibPath)
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Store (putStoreFile)
import PureScript.Backend.Wasm.Compiler (effectfulForeigns, parseModule)
import PureScript.Backend.Wasm.MiddleEnd (batchInlineKeys, emptyIncAccum, incDepStep, incMissStep, liftModule)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import Purwc.CLI.Compile (depInterfaceOf, emitModule, loadDepInterfaces)
import Purwc.CLI.Options.Types (BatchOption)
import Run (EFFECT, Run)
import Type.Row (type (+))

batchCmd :: forall r. FilePath -> FilePath -> BatchOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
batchCmd cliRoot binaryenBinDir args = do
  raw <- readStdin
  -- Each line is tab-separated `<*?>name\t<pmiStoreKey>\t<wasmStoreKey>\t<0|1 library>` (the
  -- orchestrator's store keys + library flag; a bare name with no tabs degrades to "no store keys",
  -- so a hand-run batch still works). `*` marks the program entry (host-ABI bare exports).
  let
    misses = Array.filter (not <<< Str.null <<< _.name) $
      Str.split (Pattern "\n") raw <#> \rawLine ->
        let
          cols = Str.split (Pattern "\t") (Str.trim rawLine)
          rawName = fromMaybe "" (Array.index cols 0)
          entry = Str.take 1 rawName == "*"
        in
          { entry
          , name: if entry then Str.drop 1 rawName else rawName
          , sk: fromMaybe "" (Array.index cols 1)
          , wk: fromMaybe "" (Array.index cols 2)
          , library: Array.index cols 3 == Just "1"
          }
  let missNames = Set.fromFoldable (map _.name misses)
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt, perModuleRep: false }
  libPath <- resolveLibPath cliRoot Nothing

  -- The store-hit summaries the orchestrator copied into `--deps` (= `_build`) before the batch:
  -- every staged `.pmi` whose module is NOT itself a miss. Decoded ONCE here and used to seed the
  -- optimization accumulator and the codegen dependency-interface set (a dependent never re-decodes).
  allPmis <- loadDepInterfaces args.depsDir
  let hitEntries = Array.filter (\e -> not (Set.member (Str.joinWith "." e.summary.name) missNames)) allPmis

  -- Read + lift every miss exactly once (its CoreFn, source hash, externs, and foreign sigs), so the
  -- whole-batch effectful-foreign set and `summaryInlineKeys` can be computed up front (oracle-style)
  -- and each lifted module reused in the optimize loop without re-decoding.
  missData <- for misses \mss -> do
    let target = mss.name
    let mn = entryRoot target
    corefnPath <- joinPath [ args.input, target, "corefn.json" ]
    src <- readText corefnPath >>= maybe (logAndThrow (Fmt.fmt @"corefn not found: {p}" { p: corefnPath })) pure
    decoded <- case parseModule src of
      Left err -> logAndThrow (target <> ": " <> err)
      Right m -> pure m
    externs <- map (maybe [] (\e -> [ e ])) (readExterns =<< joinPath [ args.input, target, "externs.cbor" ])
    let foreignNames = corefnForeignNames src
    allSigs <- buildForeignSigs args.input libPath externs [ { name: mn, foreignNames } ]
    pure
      { target
      , programEntry: mss.entry
      , sourceHash: hashString (toolchainTag <> "\n" <> src)
      , lifted: liftModule decoded
      , externs
      , allSigs
      , foreignNameSet: Set.fromFoldable (map (\base -> target <> "." <> base) foreignNames)
      , sk: mss.sk
      , wk: mss.wk
      , library: mss.library
      }

  -- The batch-wide effectful-foreign set (every miss's sigs ∪ every hit's foreign sigs): the optimizer
  -- must know a callee is effectful regardless of which module declares it, matching the whole-program
  -- oracle (which builds `eff` over all sigs). A superset only adds inert names — a binding that never
  -- calls a foreign is unaffected by it.
  let allSigsAll = Array.foldl Object.union Object.empty (map _.allSigs missData <> map _.foreignSigs hitEntries)
  let eff = effectfulForeigns allSigsAll

  -- All program module names (for the precise-reference filter) and the whole-program inline keyset
  -- (which bodies a summary retains), both computed ONCE — exactly as `optimizeIncrementalM` does.
  let hitNames = Array.fromFoldable (map (\e -> Str.joinWith "." e.summary.name) hitEntries)
  let names = Set.union missNames (Set.fromFoldable hitNames)
  let summaryInlineKeys = batchInlineKeys eff.names (map _.summary hitEntries <> map _.lifted missData)

  -- Seed the optimization accumulator and the codegen dependency-interface set from the hits, then
  -- thread both across the misses in topo order: optimize each against the running accumulator
  -- (`incMissStep`) and codegen it against the accumulated interfaces, appending its own.
  let accum0 = Array.foldl (\acc e -> incDepStep eff.names { name: Str.joinWith "." e.summary.name, summary: e.summary, key: e.key } acc) emptyIncAccum hitEntries
  let env = { binaryenBinDir, input: args.input, outDir: args.outDir, text: false, opts }
  _ <- foldM
    ( \st m -> do
        let
          s = incMissStep eff.names eff.arities names summaryInlineKeys
            { name: m.target, sourceHash: m.sourceHash, lifted: m.lifted }
            st.accum
        iface <- emitModule env
          { target: m.target
          , programEntry: m.programEntry
          , externs: m.externs
          , allSigs: m.allSigs
          , foreignNameSet: m.foreignNameSet
          , depInterfaces: st.depIfaces
          , sourceHash: m.sourceHash
          , finalMod: s.finalMod
          , summary: s.summary
          , deps: s.deps
          , key: s.key
          }
        -- ADR 0040 §P3: as soon as a LIBRARY module finishes, write its three artifacts to the store
        -- under the orchestrator's per-line keys (the entry + project-own modules stay in `_build`).
        -- Incremental — a crashed batch still leaves every completed library object cached.
        when (args.storeDir /= "" && m.library && not m.programEntry) do
          storeArtifacts args.storeDir args.outDir m.target m.sk m.wk
        pure { accum: s.accum, depIfaces: Array.snoc st.depIfaces iface }
    )
    { accum: accum0, depIfaces: map depInterfaceOf hitEntries }
    missData
  pure unit

-- | Copy a just-compiled library module's three `_build` artifacts into the content-addressed store
-- | under the orchestrator-supplied keys (`.pmi` under the recursive `.pmi` key, `.wasm`/`.link.json`
-- | under the codegen-specific `.wasm` key). `putStoreFile` is a no-op if the content is already
-- | present, so a re-run is idempotent.
storeArtifacts :: forall r. FilePath -> FilePath -> String -> String -> String -> Run (FS + EFFECT + r) Unit
storeArtifacts root buildDir name sk wk = do
  let
    put suffix key = do
      mb <- readBinary =<< joinPath [ buildDir, name <> suffix ]
      maybe (pure unit) (putStoreFile root (key <> suffix)) mb
  put ".pmi" sk
  put ".wasm" wk
  put ".link.json" wk
