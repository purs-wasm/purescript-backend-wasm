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
module Purwc.CLI.Compile
  ( compileCmd
  ) where

import Prelude

import Data.Argonaut.Core (fromArray, fromObject, fromString, jsonNull, stringify)
import Data.Array as Array
import Data.Either (Either(..), hush)
import Data.Maybe (Maybe(..), maybe)
import Data.Set as Set
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import Foreign.Object as Object
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, mkdirP, readBinary, readDir, readText, writeBinary, writeText)
import PureScript.Backend.Wasm.CLI.Effect.Log as Log
import PureScript.Backend.Wasm.CLI.Externs (readExterns)
import PureScript.Backend.Wasm.CLI.ForeignSigs (buildForeignSigs)
import PureScript.Backend.Wasm.CLI.Lib (resolveLibPath)
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Paths (wasmDisBin)
import PureScript.Backend.Wasm.Compiler (compileModuleWasm, effectfulForeigns, moduleInterface, parseModule)
import PureScript.Backend.Wasm.Externs (ctorFieldReps)
import PureScript.Backend.Wasm.MiddleEnd (compileModuleMir, liftModule)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (PmiEntry, decodePmi, encodePmi)
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
  let sourceHash = hashString src
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
  let
    depInterfaces = depEntries <#> \e ->
      { funcs: e.funcs
      , ctors: e.ctors
      , dictCtors: e.dictCtors
      , enumCtors: e.enumCtors
      , foreignSigs: e.foreignSigs
      , foreignNames: e.foreignNames
      }
  -- The effectful-foreign set (for impurify) must include the DEPENDENCIES' foreigns, not just the
  -- target's: the target may call a dependency's `Effect` foreign (e.g. `Effect.Console.log`), and
  -- without knowing it is effectful the optimizer mis-globalizes a top-level `Effect` binding
  -- (performing it at CAF-init). The deps' foreign sigs come from their `.pmi` (ADR 0038 M2a).
  let allSigsWithDeps = Array.foldl Object.union allSigs (map _.foreignSigs depEntries)
  let eff = effectfulForeigns allSigsWithDeps

  -- Optimize the single module against its dependency summaries, then persist its interface.
  let out = compileModuleMir eff.names eff.arities { sourceHash, lifted: liftModule decoded, depSummaries }
  mkdirP args.outDir
  pmiPath <- joinPath [ args.outDir, target <> ".pmi" ]
  let iface = moduleInterface (ctorFieldReps externs) allSigs (Set.toUnfoldable foreignNameSet) out.finalMod
  writeBinary pmiPath
    ( encodePmi
        { sourceHash
        , key: out.key
        , deps: out.deps
        , summary: out.summary
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
  liftEffect (compileModuleWasm opts allSigs foreignNameSet externs depInterfaces args.programEntry out.finalMod) >>= case _ of
    Left err -> logAndThrow err
    Right art -> do
      wasmPath <- joinPath [ args.outDir, target <> ".wasm" ]
      writeBinary wasmPath art.bytes
      info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: wasmPath })
      -- The orchestrator-facing link metadata (ADR 0038 Phase C): the per-module facts the
      -- `purs-wasm` orchestrator needs to build the link glue, resolve foreigns, and internalise
      -- cross-module exports after `wasm-merge`. Kept out of the `.pmi` (which is the dependent-facing
      -- interface); a small ephemeral JSON sidecar, read once by the orchestrator.
      linkPath <- joinPath [ args.outDir, target <> ".link.json" ]
      writeText linkPath
        ( stringify $ fromObject $ Object.fromFoldable
            [ Tuple "cafInitExport" (maybe jsonNull fromString art.cafInitExport)
            , Tuple "foreignModules" (fromArray (map fromString art.foreignModules))
            , Tuple "crossModuleExports" (fromArray (map fromString art.crossModuleExports))
            ]
        )
      when args.text do
        watPath <- joinPath [ args.outDir, target <> ".wat" ]
        execFile (wasmDisBin binaryenBinDir) [ wasmPath, "-o", watPath, "--all-features" ]
        info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: watPath })
      info $ Log.strong (Log.green (Fmt.fmt @"✓ compiled {m}" { m: target }))

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
