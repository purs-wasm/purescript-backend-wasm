-- | The public build facade: parse `corefn.json` sources and link a set of
-- | modules into one wasm binary (ADR 0009). This keeps the CLI (`purs-wasm`) free of
-- | the Argonaut / Binaryen / IR details — it only does file I/O and calls these.
module PureScript.Backend.Wasm.Compiler
  ( CompileOptions
  , CompiledModule
  , LinkCore
  , parseModule
  , linkModule
  , finishLink
  , compilePerModule
  , PerModuleArtifacts
  , compileModuleWasm
  , compileModuleWasmShared
  , ModuleArtifact
  , moduleInterface
  , ModuleInterfaceTables
  , effectfulForeigns
  , compileModules
  , compileModulesText
  , mirTrace
  , printMir
  ) where

import Prelude

import Binaryen as B
import Data.Argonaut.Decode (printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.Traversable (sequence, traverse)
import Effect (Effect)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Codegen (buildLinkGlue, buildModule, buildModuleSingle)
import PureScript.Backend.Wasm.Externs (ForeignSig, ctorFieldReps, effectfulForeignAritiesFromSigs, effectfulForeignNamesFromSigs)
import PureScript.Backend.Wasm.Intrinsics (effectfulForeignNames)
import PureScript.Backend.Wasm.Lower (DepInterface, LoweredTarget, SharedLowerInfo, lowerModuleAgainstInfo, lowerModuleWithInterfaces, lowerModules, lowerProgramFragments)
import PureScript.Backend.Wasm.Lower.Collect (collectCtors, collectDictCtors, collectEnumCtors, collectFuncs, collectLabels)
import PureScript.Backend.Wasm.Lower.IR (Rep)
import PureScript.Backend.Wasm.Lower.Types (CtorInfo)
import PureScript.Backend.Wasm.MiddleEnd (CacheInput, CacheWrite, noCache, optimizeProgramCached, optimizeProgramTrace)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Print (printModule)
import PureScript.CoreFn (Module, ModuleName)
import PureScript.CoreFn.FromJSON (decodeModule)
import PureScript.ExternsFile (ExternsFile)

-- | Parse a `corefn.json` source string into a `Module`, with failures rendered
-- | as a message.
parseModule :: String -> Either String Module
parseModule source = case jsonParser source of
  Left parseErr -> Left ("corefn parse error: " <> parseErr)
  Right json -> case decodeModule json of
    Left decodeErr -> Left ("corefn decode error: " <> printJsonDecodeError decodeErr)
    Right m -> Right m

-- | Build options. `optimize` runs Binaryen's optimizer (which also DCE-drops the
-- | non-root functions); turning it off (a debug build) keeps the wasm closer to
-- | the emitted IR — and is where source-map support will hang once CoreFn source
-- | spans are threaded through to Binaryen debug locations. `optimizeMir` toggles
-- | the middle-end (dictionary elimination); off builds an unoptimized baseline
-- | (lambda lifting still runs, since it is needed for constant-stack tail recursion).
-- | `perModuleRep` (ADR 0037 ③) constrains the representation analysis to a per-module
-- | boundary (cross-module-visible functions pinned to the boxed ABI). Off by default; the
-- | build is still whole-program, this only simulates the per-module rep for A/B measurement.
type CompileOptions = { optimize :: Boolean, optimizeMir :: Boolean, perModuleRep :: Boolean }

-- | The live result of `linkModule` (the "link" half of link/emit, ADR 0021): the built
-- | Binaryen module, the distinct user-foreign source modules to resolve (ADR 0014), and the
-- | CAF-init function (`Nothing` if none) whose run trigger — loader call vs wasm `start` — is
-- | the caller's packaging decision (ADR 0006). The caller emits and disposes `mod`.
type CompiledModule =
  { mod :: B.Module
  , foreignModules :: Array String
  , cafInit :: Maybe B.Function
  -- The incremental-cache misses produced by this link (ADR 0032 phase 4 / ADR 0034), for
  -- the caller to persist as `.pmi` + `.pmo` pairs. Empty unless a `CacheInput` with module
  -- source hashes was supplied; the caller owns the filesystem.
  , cacheWrites :: Array CacheWrite
  }

-- | Link the given modules into one validated Binaryen module and return the **live**
-- | artifact (the module, the foreign sources to resolve, the CAF-init function) — the
-- | "link" half of the link/emit split (ADR 0021). The caller owns packaging (resolve
-- | foreigns, decide the CAF-init trigger, `setStart`) and then **emits and disposes** the
-- | module. `roots` are the entry modules whose functions stay exported; everything else is
-- | internal and so removed by the optimizer's DCE (ADR 0009). Linking or validation
-- | failures come back as a message (and dispose the module). `foreignSigs` is the
-- | foreign-import calling conventions to resolve against — the caller merges any
-- | source-reconstructed signatures (ADR 0016) over the externs-derived ones, so private
-- | foreigns are covered. `externs` still supplies constructor field reps.
linkModule
  :: CompileOptions
  -> Array ModuleName
  -> Array Module
  -> Array ExternsFile
  -> Object ForeignSig
  -> CacheInput
  -> Effect (Either String CompiledModule)
linkModule opts roots modules externs foreignSigs' cache =
  finishLink opts roots foreignSigs' foreignNames externs optimized.modules optimized.writes
  where
  -- Prune to the modules transitively imported by the entry roots BEFORE optimizing — the
  -- input dir holds the whole dependency build (often hundreds of modules), but optimizing
  -- them all is wasted work and overflows the optimizer's stack on a real closure (ADR 0009;
  -- the function-level reachability DCE in `lowerModules` runs afterwards over this set).
  reachable = reachableModules roots modules
  -- every CoreFn-declared foreign name (qualified); lets lowering fall back to an
  -- all-opaque host import when a foreign has no reconstructed signature (ADR 0016)
  foreignNames = Set.fromFoldable (reachable >>= \m -> map (\base -> joinWith "." m.name <> "." <> base) m.foreignNames)
  -- the effectful-foreign set/arities (intrinsics ∪ those declared by the sigs) that the
  -- optimizer must preserve `Perform`s for; the same pair `mirTrace` uses (ADR 0015).
  effSet = Set.union effectfulForeignNames (effectfulForeignNamesFromSigs foreignSigs')
  effArities = effectfulForeignAritiesFromSigs foreignSigs'
  optimized = optimizeProgramCached opts.optimizeMir effSet effArities cache reachable

-- | The effectful-foreign set and arities (intrinsics ∪ those the signatures declare) that the
-- | optimizer must preserve `Perform`s for (ADR 0015) — exposed so the CLI can drive the per-module
-- | incremental loop (`MiddleEnd.optimizeIncrementalM`) itself, for live progress, then `finishLink`.
effectfulForeigns :: Object ForeignSig -> { names :: Set String, arities :: Map String Int }
effectfulForeigns foreignSigs' =
  { names: Set.union effectfulForeignNames (effectfulForeignNamesFromSigs foreignSigs')
  , arities: effectfulForeignAritiesFromSigs foreignSigs'
  }

-- | The back half of linking — lower the optimized MIR, build and validate the Binaryen
-- | module, package it with the cache misses — as a pluggable interface, so the CLI can choose
-- | the whole-program `finishLink` (the oracle) or the per-module `linkPerModule` (ADR 0037
-- | Phase 2) without the driver knowing which. `foreignNames` is the qualified CoreFn-declared
-- | foreign set (lowering's opaque-import fallback, ADR 0016); the rest mirror `finishLink`.
type LinkCore =
  CompileOptions
  -> Array ModuleName
  -> Object ForeignSig
  -> Set String
  -> Array ExternsFile
  -> Array M.Module
  -> Array CacheWrite
  -> Effect (Either String CompiledModule)

-- | What `compilePerModule` produces for the caller to link (ADR 0037 Phase 2): each module's
-- | already-emitted wasm bytes (to write under `<output>/_build/<module>.wasm` and `wasm-merge`),
-- | the live link-glue module (kept live so packaging can `setStart` its `caf_init` when there is
-- | no loader), the glue's `caf_init` function (`Nothing` if nothing is globalized), and the
-- | distinct user-foreign source modules to resolve.
type PerModuleArtifacts =
  { moduleBytes :: Array { moduleName :: String, bytes :: Uint8Array }
  , glue :: B.Module
  , cafInit :: Maybe B.Function
  , foreignModules :: Array String
  -- the cross-module function export names (qualified keys) each module emitted purely for
  -- `wasm-merge` to resolve cross-module calls; after merge these are redundant, so the caller
  -- internalises them and lets the optimiser DCE any now-unused (ADR 0037 ⑥, Slice 2.2c).
  , crossModuleExports :: Array String
  }

-- | Per-module compilation (ADR 0037 Phase 2, Slice 2.2): lower each module to a fragment, codegen
-- | each to its OWN Binaryen module (`buildModuleSingle` — cross-module calls become imports, this
-- | module's cross-module-referenced functions are exported), then synthesize the link glue. Each
-- | module is validated and emitted to bytes (then disposed, to bound peak memory); the glue stays
-- | live for the caller to `setStart`. Modules are emitted UNOPTIMIZED: optimising each
-- | independently could reorganise its GC types so they no longer canonicalise across modules under
-- | `wasm-merge` — the merged wasm is optimised once, after merge (Slice 2.2c). A module that fails
-- | validation returns its wat.
compilePerModule
  :: CompileOptions
  -> Array ModuleName
  -> Object ForeignSig
  -> Set String
  -> Array ExternsFile
  -> Array M.Module
  -> Effect (Either String PerModuleArtifacts)
compilePerModule opts roots foreignSigs' foreignNames externs optimizedModules =
  case lowerProgramFragments (ctorFieldReps externs) foreignSigs' foreignNames roots optimizedModules of
    Left err -> pure (Left ("linking failed: " <> show err))
    Right lowered -> do
      results <- traverse (buildOne lowered) lowered.fragments
      case sequence results of
        Left err -> pure (Left err)
        Right built -> do
          let
            cafInits = Array.mapMaybe
              (\b -> map (\e -> { moduleName: b.moduleName, cafInitExport: e }) b.cafInitExport)
              built
          glue <- buildLinkGlue cafInits
          pure
            ( Right
                { moduleBytes: built <#> \b -> { moduleName: b.moduleName, bytes: b.bytes }
                , glue: glue.mod
                , cafInit: glue.cafInit
                , foreignModules: Array.nub (built >>= _.foreignModules)
                -- internalise post-merge: the cross-module function exports (resolved by merge) AND
                -- each module's `caf_init$M` (the link glue imports + calls them, so after merge the
                -- export is redundant). The glue's own host-facing `caf_init` is a different name, so
                -- it is kept. Result: the merged export surface matches the whole-program oracle.
                , crossModuleExports: Set.toUnfoldable lowered.crossModuleRefs <> map _.cafInitExport cafInits
                }
            )
  where
  buildOne lowered f = do
    let dotted = joinWith "." f.moduleName
    let meta = { moduleName: dotted, keyHomeModule: lowered.keyHomeModule, crossModuleRefs: lowered.crossModuleRefs }
    single <- buildModuleSingle meta { funcs: f.funcs, labels: lowered.labels, exportSigs: f.exportSigs }
    ok <- B.validate single.mod
    if not ok then do
      wat <- B.emitText single.mod
      B.dispose single.mod
      pure (Left ("per-module codegen: " <> dotted <> " failed validation:\n" <> wat))
    else do
      -- Optimise each module independently (ADR 0037 Phase 3): verified to preserve cross-module GC
      -- type canonicalisation under merge, so the merged wasm needs no whole-program re-optimise —
      -- only a cheap post-merge DCE of the internalised exports. This makes the optimised per-module
      -- wasm a cacheable artifact (a changed module re-optimises alone). Imports/exports (the boxed
      -- cross-module ABI) are preserved, so merge resolution is unaffected.
      when opts.optimize (B.optimize single.mod)
      bytes <- B.emitBinary single.mod
      B.dispose single.mod
      pure (Right { moduleName: dotted, bytes, cafInitExport: single.cafInitExport, foreignModules: single.foreignModules })

-- | What `compileModuleWasm` produces for ONE module (ADR 0038 Phase B — the `purwc` worker): the
-- | module's emitted (optimised) wasm bytes ready for `wasm-merge`, its per-module CAF-init export
-- | name (`caf_init$<Module>`, `Nothing` if it globalizes none — the orchestrator's glue calls it),
-- | the foreign source modules to resolve, and the cross-module function keys this module exported
-- | for merge resolution (the orchestrator internalises + DCEs them post-merge, so over-exporting is
-- | safe). Unlike `PerModuleArtifacts`, there is no link glue — the orchestrator builds that from the
-- | per-module `cafInitExport`s of the whole program.
type ModuleArtifact =
  { bytes :: Uint8Array
  , cafInitExport :: Maybe String
  , foreignModules :: Array String
  , crossModuleExports :: Array String
  }

-- | Lower + codegen ONE module in isolation (ADR 0038 Phase B M2b). `target` is the module's
-- | finalized MIR; `deps` are its dependencies' lowering INTERFACES — loaded from their `.pmi`, never
-- | their `.pmo`. `lowerModuleWithInterfaces` builds the lowering context by merging the target's own
-- | `collect*` tables with the dep interfaces, then codegens only the target via `buildModuleSingle`
-- | (cross-module calls → imports, the target's functions → over-exported for merge). Emits NO link
-- | glue and does NO merge — the orchestrator's job (Phase C). A dependency-free module is
-- | byte-identical to the whole-program per-module oracle; a dependency-having one is
-- | behaviour-identical (over-export makes its rep-pinning, hence bytes, diverge).
compileModuleWasm
  :: CompileOptions
  -> Object ForeignSig
  -> Set String
  -> Array ExternsFile
  -> Array DepInterface
  -> Boolean
  -> M.Module
  -> Effect (Either String ModuleArtifact)
compileModuleWasm opts foreignSigs' foreignNames externs deps isEntry target =
  case lowerModuleWithInterfaces (ctorFieldReps externs) foreignSigs' foreignNames deps isEntry target of
    Left err -> pure (Left ("linking failed: " <> show err))
    Right lowered -> emitLoweredTarget opts lowered target

-- | Like `compileModuleWasm`, but lowers the target against a prebuilt whole-program lowering context
-- | (`buildSharedInfo`, ADR 0038 Phase C2) instead of folding the dependency interfaces afresh — so a
-- | long-lived `compile-batch` worker pays the interface merge ONCE for the batch, not per module
-- | (O(N) not O(N²)). The emitted artifact is behaviour-identical (the shared context's extra,
-- | non-dependency entries are inert).
compileModuleWasmShared :: CompileOptions -> SharedLowerInfo -> Boolean -> M.Module -> Effect (Either String ModuleArtifact)
compileModuleWasmShared opts shared isEntry target =
  case lowerModuleAgainstInfo shared isEntry target of
    Left err -> pure (Left ("linking failed: " <> show err))
    Right lowered -> emitLoweredTarget opts lowered target

-- | Codegen a lowered target to its (optimised) wasm bytes + link facts, shared by the per-module
-- | (`compileModuleWasm`) and shared-context (`compileModuleWasmShared`) lowering paths.
emitLoweredTarget :: CompileOptions -> LoweredTarget -> M.Module -> Effect (Either String ModuleArtifact)
emitLoweredTarget opts lowered target = do
  let dotted = joinWith "." target.name
  let meta = { moduleName: dotted, keyHomeModule: lowered.keyHomeModule, crossModuleRefs: lowered.crossModuleRefs }
  single <- buildModuleSingle meta { funcs: lowered.fragment.funcs, labels: lowered.labels, exportSigs: lowered.fragment.exportSigs }
  ok <- B.validate single.mod
  if not ok then do
    wat <- B.emitText single.mod
    B.dispose single.mod
    pure (Left ("per-module codegen: " <> dotted <> " failed validation:\n" <> wat))
  else do
    when opts.optimize (B.optimize single.mod)
    bytes <- B.emitBinary single.mod
    B.dispose single.mod
    -- Over-export the cross-module-referenced keys HOMED in this module (merge resolves them;
    -- the orchestrator internalises + DCEs post-merge) plus this module's own `caf_init$M`.
    let homed = Set.toUnfoldable (Set.filter (\k -> Object.lookup k lowered.keyHomeModule == Just dotted) lowered.crossModuleRefs)
    pure
      ( Right
          { bytes
          , cafInitExport: single.cafInitExport
          , foreignModules: single.foreignModules
          , crossModuleExports: homed <> maybe [] (\e -> [ e ]) single.cafInitExport
          }
      )

-- | The lowering-interface tables of ONE module (ADR 0038 Phase B): the symbol signatures a
-- | dependent merges into its `ModuleInfo` to lower this module's cross-module callees — derived
-- | from this module's OWN finalized MIR via the existing `collect*` passes and serialized into its
-- | `.pmi`, so the dependent never reads this module's `.pmo`. `foreignSigs` is filtered to the
-- | foreigns THIS module declares; `foreignNames` is the module's full qualified foreign-name set
-- | (the lowering opaque fallback). `labels` is carried for the orchestrator's pre-merge
-- | hash-collision check (Phase C), NOT for a dependent's lowering.
type ModuleInterfaceTables =
  { funcs :: Object Int
  , ctors :: Object CtorInfo
  , dictCtors :: Object Unit
  , enumCtors :: Object Unit
  , foreignSigs :: Object ForeignSig
  , foreignNames :: Array String
  , labels :: Object Int
  }

moduleInterface :: Object (Array Rep) -> Object ForeignSig -> Array String -> M.Module -> ModuleInterfaceTables
moduleInterface fieldReps allForeignSigs foreignNames m =
  let
    dotted = joinWith "." m.name
    dictCtors = collectDictCtors [ m ]
  in
    { funcs: collectFuncs dictCtors [ m ]
    , ctors: collectCtors fieldReps [ m ]
    , dictCtors
    , enumCtors: collectEnumCtors [ m ]
    -- only the foreigns THIS module declares (the whole-program `allForeignSigs` is filtered by
    -- the declaring module, so a dependent reading this `.pmi` gets exactly this module's foreigns).
    , foreignSigs: Object.filter (\sig -> sig.moduleName == dotted) allForeignSigs
    , foreignNames
    , labels: collectLabels [ m ]
    }

-- | The shared back half of linking: lower the optimized MIR, build and validate the Binaryen
-- | module, and package it with the cache misses to persist. `foreignNames` is the qualified
-- | CoreFn-declared foreign set (for lowering's opaque-import fallback, ADR 0016).
finishLink :: LinkCore
finishLink opts roots foreignSigs' foreignNames externs optimizedModules cacheWrites =
  case lowerModules opts.perModuleRep opts.optimizeMir (ctorFieldReps externs) foreignSigs' foreignNames roots optimizedModules of
    Left err -> pure (Left ("linking failed: " <> show err))
    Right program -> do
      built <- buildModule program
      when opts.optimize (B.optimize built.mod)
      ok <- B.validate built.mod
      if not ok then do
        wat <- B.emitText built.mod
        B.dispose built.mod
        pure (Left ("emitted module failed validation:\n" <> wat))
      else pure (Right { mod: built.mod, foreignModules: built.foreignModules, cafInit: built.cafInit, cacheWrites })

-- | The modules transitively reachable from `roots` through CoreFn imports (a fixpoint over
-- | each kept module's import list). Used to drop unreached dependency modules before the
-- | middle-end runs.
reachableModules :: Array ModuleName -> Array Module -> Array Module
reachableModules roots modules = Array.filter (\m -> Set.member (joinWith "." m.name) keep) modules
  where
  keep = fixpoint (Set.fromFoldable (map (joinWith ".") roots))

  fixpoint :: Set String -> Set String
  fixpoint seen =
    let
      next = Array.foldl addImports seen modules
    in
      if Set.size next == Set.size seen then seen else fixpoint next
  addImports seen m
    | Set.member (joinWith "." m.name) seen =
        Set.union seen (Set.fromFoldable (map (\i -> joinWith "." i.moduleName) m.imports))
    | otherwise = seen

-- | Link the given modules into one wasm and return its binary bytes. `externs`
-- | supplies type information for type-directed lowering (front B); pass `[]` to
-- | build without it (everything stays boxed). This is the whole-program convenience that
-- | runs CAF init via the wasm `start` section (suitable for a self-contained build with no
-- | re-entrant JS foreigns); the CLI uses `linkModule` directly so packaging can decide the
-- | CAF-init trigger (ADR 0006 / 0021).
compileModules :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Object ForeignSig -> Effect (Either String Uint8Array)
compileModules opts roots modules externs sigs =
  linkModule opts roots modules externs sigs noCache >>= traverse (emitAndDispose B.emitBinary)

-- | Link the given modules into one wasm and return its WAT (text) form.
compileModulesText :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Object ForeignSig -> Effect (Either String String)
compileModulesText opts roots modules externs sigs =
  linkModule opts roots modules externs sigs noCache >>= traverse (emitAndDispose B.emitText)

-- | Run CAF init via the wasm `start` section, then emit and dispose the module — the
-- | self-contained path (`compileModules`/`compileModulesText`). The CLI instead emits via
-- | `linkModule` so it can route CAF init through the loader (ADR 0006 / 0021).
emitAndDispose :: forall a. (B.Module -> Effect a) -> CompiledModule -> Effect a
emitAndDispose emit built = do
  maybe (pure unit) (B.setStart built.mod) built.cafInit
  out <- emit built.mod
  B.dispose built.mod
  pure out

-- | Trace the named module's middle IR (MIR) — its form after specialization and after it
-- | is optimized (simplify → impurify → simplify) — the `--dump-mir` companion to the
-- | normal build, using the *same* effectful-foreign set/arities so the trace matches the
-- | real pipeline. `target` is a dotted module name (e.g. `Examples.EffRef.Main`).
mirTrace :: CompileOptions -> Array Module -> Object ForeignSig -> String -> String
mirTrace opts modules foreignSigs' target =
  joinWith "\n\n" (optimizeProgramTrace opts.optimizeMir effSet effArities target modules)
  where
  effSet = Set.union effectfulForeignNames (effectfulForeignNamesFromSigs foreignSigs')
  effArities = effectfulForeignAritiesFromSigs foreignSigs'

-- | Pretty-print a module's optimized MIR (the form held in a `.pmo`), for the `--dump-mir`
-- | companion on a cached build: the cache has only the *final* optimized module (not the
-- | per-stage trace `mirTrace` produces), so this dumps that, decoded from the `.pmo`.
printMir :: M.Module -> String
printMir = printModule
