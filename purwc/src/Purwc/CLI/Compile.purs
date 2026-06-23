-- | The `compile` command (ADR 0038 Phase B): compile ONE module in isolation — load its
-- | `corefn.json` + `externs.cbor` and its dependencies' `.pmi` INTERFACES (from `--deps`), optimize
-- | it against the deps' summaries (`compileModuleMir`), then lower + codegen it against the deps'
-- | lowering interfaces (`compileModuleWasm`), writing its `.pmi` + `.wasm` (+ `.wat` on `--text`).
-- | The worker reads ONLY `.pmi` from its dependencies — never their `.pmo` — and emits NO link glue
-- | and does NO merge (the `purs-wasm` orchestrator's job, Phase C). It writes NO `.pmo`: that object
-- | half is being retired now the per-module `.wasm` is the compiled output and the `.pmi` is the
-- | complete interface.
-- |
-- | `--deps` is expected to hold exactly this module's transitive dependency `.pmi`s (the orchestrator
-- | provides the closure). The summary fold is order-independent (each summary already encodes its
-- | module's final optimization context), so no topological ordering is needed here.
-- |
-- | The codegen + artifact-write tail is shared with the long-lived `compile-batch` worker via
-- | `emitModule`; the batch worker (`Purwc.CLI.Batch`) drives the incremental optimizer itself
-- | rather than calling `compileModuleMir` per module, so it never re-folds every dependency summary.
module Purwc.CLI.Compile
  ( compileCmd
  , emitModule
  , depInterfaceOf
  , loadDepInterfaces
  , EmitEnv
  , ModuleArtifactInput
  ) where

import Prelude

import Data.Argonaut.Core (fromArray, fromObject, fromString, jsonNull, stringify)
import Data.Array as Array
import Data.Either (Either(..), hush)
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Map as Map
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.CLI.Compat (toolchainTag)
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, mkdirP, readBinary, readDir, readText, unlink, writeBinary, writeText)
import PureScript.Backend.Wasm.CLI.ForeignWasm (foreignProvider, mergeForeignInto)
import PureScript.Backend.Wasm.CLI.Effect.Log as Log
import PureScript.Backend.Wasm.CLI.Externs (readExterns)
import PureScript.Backend.Wasm.CLI.ForeignSigs (buildForeignSigs)
import PureScript.Backend.Wasm.CLI.Lib (resolveLibPath)
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Paths (wasmDisBin)
import PureScript.Backend.Wasm.Compiler (CompileOptions, compileModuleWasm, effectfulForeigns, moduleInterface, parseModule)
import PureScript.Backend.Wasm.Externs (ForeignSig, ctorFieldReps)
import PureScript.Backend.Wasm.Lower (DepInterface)
import PureScript.Backend.Wasm.Lower.Types (CtorInfo)
import PureScript.Backend.Wasm.MiddleEnd (compileModuleMir, declRefMap, liftModule)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (PmiEntry, decodePmi, encodePmi)
import PureScript.ExternsFile (ExternsFile)
import Purwc.CLI.Options.Types (CompileOption)
import Run (EFFECT, Run, liftEffect)
import Type.Row (type (+))

compileCmd :: forall r. FilePath -> FilePath -> CompileOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
compileCmd cliRoot binaryenBinDir args = do
  let target = args.entryModule
  let mn = entryRoot target
  info $ Log.strong (Log.cyan (Fmt.fmt @"purwc — compiling {m}" { m: target }))
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt, perModuleRep: false }

  -- The target's CoreFn (decoded for the full optimize/codegen) + cheap metadata (source hash for
  -- the cache key, the bare foreign-import names for lowering's qualified foreign set).
  corefnPath <- joinPath [ args.input, target, "corefn.json" ]
  src <- readText corefnPath >>= maybe (logAndThrow (Fmt.fmt @"corefn not found: {p}" { p: corefnPath })) pure
  decoded <- case parseModule src of
    Left err -> logAndThrow (target <> ": " <> err)
    Right m -> pure m
  -- ADR 0040: fold the `.pmi`-affecting toolchain axes into the source hash (shared with the
  -- orchestrator's `Build.purs`, so the keys agree — the `diffPurwc` byte-parity contract).
  let sourceHash = hashString (toolchainTag <> "\n" <> src)
  let foreignNames = corefnForeignNames src

  -- The target's externs (type info / ctor field reps) + its foreign calling-convention signatures.
  libPath <- resolveLibPath cliRoot Nothing
  externs <- map (maybe [] (\e -> [ e ])) (readExterns =<< joinPath [ args.input, target, "externs.cbor" ])
  allSigs <- buildForeignSigs args.input libPath externs [ { name: mn, foreignNames } ]
  let foreignNameSet = Set.fromFoldable (map (\base -> target <> "." <> base) foreignNames)

  -- The dependency interfaces (`.pmi` ONLY). The summary half feeds the optimizer's context; the
  -- lowering-table half feeds codegen's cross-module callee resolution.
  -- EXCLUDE this module's OWN `.pmi` if a stale copy sits in the shared deps/out dir (the orchestrator
  -- uses one `_build` dir for both `--deps` and `-O`): optimizing a module against its own previous
  -- summary re-inlines its own bindings (e.g. the derived `genericShow` instances) into itself, which
  -- the whole-program optimizer never does — a 9× code-size blowup that then stalls Binaryen.
  depEntries <- Array.filter (\e -> e.summary.name /= mn) <$> loadDepInterfaces args.depsDir
  let depSummaries = map _.summary depEntries
  -- ADR 0040 §2: the dependencies' own cache keys (dotted name → `.pmi` key), read straight from
  -- their `.pmi`s, so this module is keyed recursively against them (matching the whole-program
  -- loop's topo-accumulated dep keys → byte-identical `.pmi` key, the `diffPurwc` parity contract).
  let depKeys = Map.fromFoldable (map (\e -> Tuple (Str.joinWith "." e.summary.name) e.key) depEntries)
  let depInterfaces = map depInterfaceOf depEntries
  -- The effectful-foreign set (for impurify) must include the DEPENDENCIES' foreigns, not just the
  -- target's: the target may call a dependency's `Effect` foreign (e.g. `Effect.Console.log`), and
  -- without knowing it is effectful the optimizer mis-globalizes a top-level `Effect` binding
  -- (performing it at CAF-init). The deps' foreign sigs come from their `.pmi` (ADR 0038 M2a).
  let allSigsWithDeps = Array.foldl Object.union allSigs (map _.foreignSigs depEntries)
  let eff = effectfulForeigns allSigsWithDeps

  -- Optimize the single module against its dependency summaries, then emit its artifacts.
  let out = compileModuleMir eff.names eff.arities { sourceHash, lifted: liftModule decoded, depSummaries, depKeys }
  _ <- emitModule
    { binaryenBinDir, input: args.input, outDir: args.outDir, text: args.text, opts }
    { target
    , programEntry: args.programEntry
    , externs
    , allSigs
    , foreignNameSet
    , depInterfaces
    , sourceHash
    , finalMod: out.finalMod
    , summary: out.summary
    , deps: out.deps
    , key: out.key
    }
  pure unit

-- | The per-module codegen + artifact-write tail, shared by the one-shot `compile` and the
-- | long-lived `compile-batch` worker. Writes the module's `.pmi` interface, lowers + codegens its
-- | `.wasm` against the accumulated dependency interfaces, self-merges any kept foreign provider, and
-- | emits the `.link.json` orchestrator sidecar (+ `.wat` on `--text`). Returns the module's OWN
-- | `DepInterface` so the batch loop can accumulate it for subsequent modules' codegen without
-- | re-reading the just-written `.pmi`.
type EmitEnv =
  { binaryenBinDir :: FilePath
  , input :: FilePath
  , outDir :: FilePath
  , text :: Boolean
  , opts :: CompileOptions
  }

type ModuleArtifactInput =
  { target :: String
  , programEntry :: Boolean
  , externs :: Array ExternsFile
  , allSigs :: Object ForeignSig
  , foreignNameSet :: Set String
  , depInterfaces :: Array DepInterface
  , sourceHash :: String
  , finalMod :: M.Module
  , summary :: M.Module
  , deps :: Array String
  , key :: String
  }

emitModule :: forall r. EmitEnv -> ModuleArtifactInput -> Run (FS + PROC + LOG + EFFECT + r) DepInterface
emitModule env m = do
  let target = m.target
  mkdirP env.outDir
  pmiPath <- joinPath [ env.outDir, target <> ".pmi" ]
  let iface = moduleInterface (ctorFieldReps m.externs) m.allSigs (Set.toUnfoldable m.foreignNameSet) m.finalMod
  writeBinary pmiPath
    ( encodePmi
        { sourceHash: m.sourceHash
        , key: m.key
        , deps: m.deps
        , summary: m.summary
        , funcs: iface.funcs
        , ctors: iface.ctors
        , dictCtors: iface.dictCtors
        , enumCtors: iface.enumCtors
        , foreignSigs: iface.foreignSigs
        , foreignNames: iface.foreignNames
        , labels: iface.labels
        }
    )

  -- Lower + codegen the single module against its dependency interfaces, and write its wasm.
  liftEffect (compileModuleWasm env.opts m.allSigs m.foreignNameSet m.externs m.depInterfaces m.programEntry m.finalMod) >>= case _ of
    Left err -> logAndThrow err
    Right art -> do
      wasmPath <- joinPath [ env.outDir, target <> ".wasm" ]
      writeBinary wasmPath art.bytes
      -- ADR 0040 §P2: merge this module's own kept foreign (staged under `-I` as `{M}/foreign.wasm`
      -- or `foreign.wat`) into its wasm, so `{M}.wasm` is a self-contained object — a cross-module
      -- foreign import resolves from the owner's wasm at the program's final merge, not a re-resolve
      -- by the orchestrator (which therefore only handles genuine JS-fallback foreigns).
      foreignProvider env.binaryenBinDir env.input env.input env.outDir target >>= case _ of
        Just prov -> do
          mergeForeignInto env.binaryenBinDir wasmPath target prov.wasm
          when prov.assembled (unlink prov.wasm)
        Nothing -> pure unit
      info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: wasmPath })
      -- The orchestrator-facing link metadata (ADR 0038 Phase C): the per-module facts the
      -- `purs-wasm` orchestrator needs to build the link glue, resolve foreigns, and internalise
      -- cross-module exports after `wasm-merge`. Kept out of the `.pmi` (which is the dependent-facing
      -- interface); a small ephemeral JSON sidecar, read once by the orchestrator.
      linkPath <- joinPath [ env.outDir, target <> ".link.json" ]
      writeText linkPath
        ( stringify $ fromObject $ Object.fromFoldable
            [ Tuple "cafInitExport" (maybe jsonNull fromString art.cafInitExport)
            , Tuple "foreignModules" (fromArray (map fromString art.foreignModules))
            , Tuple "crossModuleExports" (fromArray (map fromString art.crossModuleExports))
            -- ADR 0040 §P2 / #19: the per-binding reference graph, so the orchestrator can compute
            -- entry reachability and only run a module's `caf_init$M` when it is reachable (a dead
            -- CAF whose init calls a non-marshallable foreign must never be eagerly initialized).
            , Tuple "bindingRefs"
                ( fromObject $ Object.fromFoldable
                    (declRefMap m.finalMod <#> \(Tuple k refs) -> Tuple k (fromArray (map fromString refs)))
                )
            ]
        )
      when env.text do
        watPath <- joinPath [ env.outDir, target <> ".wat" ]
        execFile (wasmDisBin env.binaryenBinDir) [ wasmPath, "-o", watPath, "--all-features" ]
        info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: watPath })
      info $ Log.strong (Log.green (Fmt.fmt @"✓ compiled {m}" { m: target }))
      pure (depInterfaceOf iface)

-- | The codegen-facing dependency interface (`DepInterface`) projected from a `.pmi` entry or a
-- | freshly-computed module interface (both share the field shape; `labels` is orchestrator-only).
depInterfaceOf
  :: forall r
   . { funcs :: Object Int
     , ctors :: Object CtorInfo
     , dictCtors :: Object Unit
     , enumCtors :: Object Unit
     , foreignSigs :: Object ForeignSig
     , foreignNames :: Array String
     | r
     }
  -> DepInterface
depInterfaceOf e =
  { funcs: e.funcs
  , ctors: e.ctors
  , dictCtors: e.dictCtors
  , enumCtors: e.enumCtors
  , foreignSigs: e.foreignSigs
  , foreignNames: e.foreignNames
  }

-- | Load every `.pmi` under `depsDir` (the transitive dependency interfaces). An empty `depsDir` or
-- | an unreadable/corrupt `.pmi` simply contributes nothing — a missing dependency surfaces later as
-- | a hard `unknown callee` from lowering, not a silent miscompile.
loadDepInterfaces :: forall r. FilePath -> Run (FS + EFFECT + r) (Array PmiEntry)
loadDepInterfaces depsDir
  | depsDir == "" = pure []
  | otherwise =
      do
        names <- maybe [] (Array.filter (isSuffix ".pmi")) <$> readDir depsDir
        map Array.catMaybes $ for names \name -> do
          bytes <- readBinary =<< joinPath [ depsDir, name ]
          pure (bytes >>= (hush <<< decodePmi))
      where
      isSuffix suf s = Str.drop (Str.length s - Str.length suf) s == suf
