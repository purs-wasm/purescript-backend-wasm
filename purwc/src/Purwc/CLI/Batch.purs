-- | The `compile-batch` command (ADR 0038 Phase C2): a long-lived worker that compiles EVERY module
-- | in a stdin work-list, in order, within ONE process. The orchestrator streams the
-- | topologically-ordered list; each line is one of:
-- |
-- |   * `@<name>\t<pmiStoreKey>`                      — a store HIT (a library dependency already
-- |       compiled): the worker reads its `.pmi` straight from `$PURS_WASM_STORE/<key>.pmi` to seed
-- |       the optimization context. Its `.wasm`/`.link.json` are NOT needed here (the orchestrator
-- |       links them from the store directly).
-- |   * `<*?><name>\t<pmiKey>\t<wasmKey>\t<0|1 library>` — a MISS to compile (`*` = the program entry).
-- |
-- | `_build` (`-O`) holds the project's OWN modules only (ADR 0040): a compiled LIBRARY module's
-- | artifacts go to the content-addressed store (keyed by the orchestrator's `<pmiKey>`/`<wasmKey>`)
-- | and are removed from `_build`, so library artifacts never accumulate there across builds. A
-- | library dependency's `.pmi` is therefore read from the store (the `@` hit lines), never copied
-- | into `_build`.
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
import Data.Either (Either(..), hush)
import Data.Foldable (foldM, for_)
import Data.FoldableWithIndex (forWithIndex_)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as Str
import Data.Traversable (for)
import Foreign.Object as Object
import Fmt as Fmt
import PureScript.Backend.Wasm.CLI.Compat (toolchainTag)
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, joinPath, logAndThrow, readBinary, readStdin, readText, unlink)
import PureScript.Backend.Wasm.CLI.Externs (readExterns)
import PureScript.Backend.Wasm.CLI.ForeignSigs (buildForeignSigs)
import PureScript.Backend.Wasm.CLI.Lib (resolveLibPath)
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Store (putStoreFile)
import PureScript.Backend.Wasm.Compiler (compileModuleWasmShared, effectfulForeigns, parseModule)
import PureScript.Backend.Wasm.Lower (buildSharedInfo)
import PureScript.Backend.Wasm.MiddleEnd (batchInlineKeys, emptyIncAccum, incDepStep, incMissStep, liftModule)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (decodePmi)
import Purwc.CLI.Compile (codegenArtifact, depInterfaceOf, writeModulePmi)
import Purwc.CLI.Options.Types (BatchOption)
import Effect (Effect)
import Run (EFFECT, Run, liftEffect)
import Type.Row (type (+))

-- | Whether the worker's stderr is a TTY (live progress is rendered only then) + a raw stderr write
-- | (no trailing newline) for the carriage-return-overwritten progress line. See `Batch.js`.
foreign import stderrIsTTY :: Boolean
foreign import progressWriteImpl :: String -> Effect Unit

batchCmd :: forall r. FilePath -> FilePath -> BatchOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
batchCmd cliRoot binaryenBinDir args = do
  raw <- readStdin
  -- Split the work-list into store HITS (`@`-prefixed: `@<name>\t<pmiStoreKey>`) and MISSES to compile
  -- (`<*?>name\t<pmiKey>\t<wasmKey>\t<0|1 library>`; `*` = program entry). A bare miss name with no
  -- tabs degrades to "no store keys", so a hand-run batch still works.
  let lines = Array.filter (not <<< Str.null) (map Str.trim (Str.split (Pattern "\n") raw))
  let { yes: hitLines, no: missLines } = Array.partition (\l -> Str.take 1 l == "@") lines
  let
    misses = missLines <#> \rawLine ->
      let
        cols = Str.split (Pattern "\t") rawLine
        rawName = fromMaybe "" (Array.index cols 0)
        entry = Str.take 1 rawName == "*"
      in
        { entry
        , name: if entry then Str.drop 1 rawName else rawName
        , sk: fromMaybe "" (Array.index cols 1)
        , wk: fromMaybe "" (Array.index cols 2)
        , library: Array.index cols 3 == Just "1"
        }
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt, perModuleRep: false }
  libPath <- resolveLibPath cliRoot Nothing

  -- The store-hit summaries: read each hit's `.pmi` straight from the store (`<store>/<pmiKey>.pmi`),
  -- decoded ONCE, to seed the optimization accumulator + the codegen dependency-interface set. A
  -- corrupt/missing artifact contributes nothing (surfaces later as a hard `unknown callee`).
  hitEntries <- map Array.catMaybes $ for hitLines \l -> do
    let sk = fromMaybe "" (Array.index (Str.split (Pattern "\t") l) 1)
    bytes <- readBinary =<< joinPath [ args.storeDir, sk <> ".pmi" ]
    pure (bytes >>= (hush <<< decodePmi))

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
  let names = Set.union (Set.fromFoldable (map _.name misses)) (Set.fromFoldable hitNames)
  let summaryInlineKeys = batchInlineKeys eff.names (map _.summary hitEntries <> map _.lifted missData)

  let env = { binaryenBinDir, input: args.input, outDir: args.outDir, text: false, opts, quiet: true }

  -- PHASE 1 (optimize): thread the incremental accumulator across the misses in topo order, optimizing
  -- each against the running accumulator (`incMissStep`) — the same O(N) accumulation the in-process
  -- whole-program loop does — and write each module's `.pmi` interface. Collect each finalized MIR +
  -- its codegen-facing `DepInterface` for the shared lowering context.
  let accum0 = Array.foldl (\acc e -> incDepStep eff.names { name: Str.joinWith "." e.summary.name, summary: e.summary, key: e.key } acc) emptyIncAccum hitEntries
  phase1 <- foldM
    ( \st m -> do
        let
          s = incMissStep eff.names eff.arities names summaryInlineKeys
            { name: m.target, sourceHash: m.sourceHash, lifted: m.lifted }
            st.accum
        di <- writeModulePmi env
          { target: m.target
          , externs: m.externs
          , allSigs: m.allSigs
          , foreignNameSet: m.foreignNameSet
          , sourceHash: m.sourceHash
          , finalMod: s.finalMod
          , summary: s.summary
          , deps: s.deps
          , key: s.key
          }
        pure
          { accum: s.accum
          , done: Array.snoc st.done
              { target: m.target, programEntry: m.programEntry, finalMod: s.finalMod, sk: m.sk, wk: m.wk, library: m.library, di }
          }
    )
    { accum: accum0, done: [] }
    missData

  -- The whole-program lowering context, built ONCE from every module's interface (hits + all misses):
  -- so each module's codegen below lowers against a shared, prebuilt `ModuleInfo` rather than re-merging
  -- every dependency interface per module (O(N), not O(N²) over the batch — ADR 0038 Phase C2).
  let shared = buildSharedInfo (map depInterfaceOf hitEntries <> map _.di phase1.done)

  -- PHASE 2 (codegen): lower + codegen each miss against the shared context, write its `.wasm` +
  -- `.link.json`. A compiled LIBRARY module's artifacts are written to the content-addressed store
  -- under the orchestrator's keys as soon as it finishes (ADR 0040 §P3) and then REMOVED from
  -- `_build`, so `_build` holds the project's own modules only; the entry + own modules stay in
  -- `_build`. With no store ($PURS_WASM_STORE unset) there is nowhere to put library artifacts, so
  -- they stay in `_build` (the pre-store fallback).
  let total = Array.length phase1.done
  forWithIndex_ phase1.done \ix d -> do
    -- Live progress on stderr (TTY only): a carriage-return-overwritten ` >  [i of n] Compiling M`,
    -- matching the whole-program build's progress line (the orchestrator's stdout owns the framing).
    when stderrIsTTY $ liftEffect $ progressWriteImpl
      ("\r\x1b[36m >  [" <> show (ix + 1) <> " of " <> show total <> "] Compiling " <> d.target <> "\x1b[0m\x1b[K")
    codegenArtifact env d.target d.finalMod
      (compileModuleWasmShared opts shared d.programEntry d.finalMod)
    when (args.storeDir /= "" && d.library && not d.programEntry) do
      storeArtifacts args.storeDir args.outDir d.target d.sk d.wk
      for_ [ ".pmi", ".wasm", ".link.json" ] \suffix ->
        unlink =<< joinPath [ args.outDir, d.target <> suffix ]
  -- Erase the progress line so the orchestrator's next message starts clean.
  when (stderrIsTTY && total > 0) $ liftEffect $ progressWriteImpl "\r\x1b[K"

-- | Copy a just-compiled library module's three `_build` artifacts into the content-addressed store
-- | under the orchestrator-supplied keys (`.pmi` under the recursive `.pmi` key, `.wasm`/`.link.json`
-- | under the codegen-specific `.wasm` key). `putStoreFile` is a no-op if the content is already
-- | present, so a re-run is idempotent. The caller removes the `_build` copies afterwards (own-only).
storeArtifacts :: forall r. FilePath -> FilePath -> String -> String -> String -> Run (FS + EFFECT + r) Unit
storeArtifacts root buildDir name sk wk = do
  let
    put suffix key = do
      mb <- readBinary =<< joinPath [ buildDir, name <> suffix ]
      maybe (pure unit) (putStoreFile root (key <> suffix)) mb
  put ".pmi" sk
  put ".wasm" wk
  put ".link.json" wk
