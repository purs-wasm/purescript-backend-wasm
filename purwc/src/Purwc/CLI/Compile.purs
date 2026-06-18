-- | The `compile` command (ADR 0038 Phase B): compile ONE module in isolation — load its
-- | `corefn.json` + `externs.cbor`, optimize it against its dependencies' `.pmi` summaries
-- | (`compileModuleMir`), write its `.pmi`/`.pmo`, then lower + codegen it (`compileModuleWasm`) and
-- | write its `.wasm` (and `.wat` on `--text`). The worker emits NO link glue and does NO merge —
-- | those are the `purs-wasm` orchestrator's job (Phase C). This is the M1 slice: dependency loading
-- | is deferred (M2), so `depSummaries`/`depFinalMods` are empty here.
module Purwc.CLI.Compile
  ( compileCmd
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Data.Set as Set
import Fmt as Fmt
import PureScript.Backend.Wasm.CLI.Corefn (corefnForeignNames)
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, mkdirP, readText, writeBinary)
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
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (encodePmi)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (encodePmo)
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
  -- M1 has no dependencies, so only the target contributes.
  libPath <- resolveLibPath cliRoot Nothing
  externs <- map (maybe [] (\e -> [ e ])) (readExterns =<< joinPath [ args.input, target, "externs.cbor" ])
  allSigs <- buildForeignSigs args.input libPath externs [ { name: mn, foreignNames } ]
  let eff = effectfulForeigns allSigs
  let foreignNameSet = Set.fromFoldable (map (\base -> target <> "." <> base) foreignNames)

  -- Optimize the single module (no dependency summaries in M1), then persist its interface/object.
  let out = compileModuleMir eff.names eff.arities { sourceHash, lifted: liftModule decoded, depSummaries: [] }
  mkdirP args.outDir
  pmiPath <- joinPath [ args.outDir, target <> ".pmi" ]
  pmoPath <- joinPath [ args.outDir, target <> ".pmo" ]
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
  writeBinary pmoPath (encodePmo out.finalMod)

  -- Lower + codegen the single module (no dependency finalMods in M1) and write its wasm.
  liftEffect (compileModuleWasm opts allSigs foreignNameSet externs [] out.finalMod) >>= case _ of
    Left err -> logAndThrow err
    Right art -> do
      wasmPath <- joinPath [ args.outDir, target <> ".wasm" ]
      writeBinary wasmPath art.bytes
      info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: wasmPath })
      when args.text do
        watPath <- joinPath [ args.outDir, target <> ".wat" ]
        execFile (wasmDisBin binaryenBinDir) [ wasmPath, "-o", watPath, "--all-features" ]
        info $ Log.blue (Fmt.fmt @"✓ Wrote {f}" { f: watPath })
      info $ Log.strong (Log.green (Fmt.fmt @"✓ compiled {m}" { m: target }))
