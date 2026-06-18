-- | The middle-end (optimization layer) facade: translate each module's CoreFn to
-- | the middle IR (ADR 0005) and apply the optimization passes, yielding MIR that
-- | the backend lowering consumes directly. The optimization *context* (inline set,
-- | transparent constructors, purity) is built **whole-program** — dictionary
-- | elimination and general inlining cross module boundaries — but modules are then
-- | optimized one at a time in dependency order, each against the already-finalized
-- | modules (ADR 0021), not in a single whole-program rewrite.
-- |
-- | Pipeline: translate → lambda lifting (per module) → higher-order specialization
-- | (whole-program, once) → dependency-ordered per-module optimization, each module
-- | running simplify (dictionary elimination + inlining) → impurify (Effect glue) →
-- | simplify again.
module PureScript.Backend.Wasm.MiddleEnd
  ( optimizeProgram
  , optimizeProgramCached
  , optimizeIncremental
  , optimizeIncrementalM
  , optimizeProgramTrace
  , optimizeModule
  , compileModuleMir
  , SingleModuleInput
  , SingleModuleOutput
  , liftModule
  , CacheInput
  , CacheEntry
  , CacheWrite
  , IncInput
  , noCache
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldM)
import Data.Identity (Identity)
import Data.Map (Map)
import Data.Newtype (unwrap)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith, contains, Pattern(..))
import Data.String as Str
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (key, references)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim as DictElim
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify (impurifyProgram)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Inline as Inline
import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity as Purity
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify (Ctx)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (specializeModule, specializationCalleeKeys)
import PureScript.Backend.Wasm.MiddleEnd.Print (printModule)
import PureScript.Backend.Wasm.MiddleEnd.Serialize (encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (cacheKey, hashBytes)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind)
import PureScript.CoreFn (Module)

-- | The accumulated dependency context (ADR 0021 b1 / incremental): the inline set, transparent /
-- | data constructors, and instance-field maps contributed by the already-finalized modules. It is
-- | grown by one module's contribution as each module finalizes, so a module is optimized against
-- | `accCtx ⊕ its own contribution` rather than by rebuilding the context over every accumulated
-- | summary each step — turning the per-module loop from O(N²) to O(N) in the module count.
type AccumCtx =
  { inline :: Map String M.Expr
  , newtypeCtors :: Set String
  , dataCtors :: Set String
  , instanceFields :: Map String (Array (Tuple String M.Expr))
  }

-- | Translate and optimize a whole program to MIR. Each module's name is kept; only
-- | its top-level bindings are represented (lambda lifting may also prepend lifted
-- | supercombinators).
-- |
-- | Modules are optimized in dependency order, each once against the already-finalized
-- | modules (ADR 0021): eliminating a dictionary turns a method binding into a fresh
-- | inlinable alias (`add = Data.Semiring.add(semiringInt)` becomes `add = intAdd`),
-- | and since a dependency is finalized before its dependents, a dependent inlines the
-- | already-reduced alias so a use `add(x, y)` becomes the intrinsic directly. (This
-- | replaced an older whole-program fixed-point loop that re-ran inlining to
-- | convergence and blew up on transformer-heavy code.)
-- | `dictElim` toggles the optimization passes; lambda lifting always runs, since it is
-- | what makes deep tail recursion run in constant stack (disabling it would overflow).
-- | Pass `false` to build an unoptimized baseline.
optimizeProgram :: Boolean -> Set String -> Map String Int -> Array Module -> Array M.Module
optimizeProgram dictElim eff arities modules = (runOpt dictElim eff arities noCache Nothing modules).modules

-- | The incremental-build inputs (ADR 0032 phase 4): each module's source hash (its
-- | `corefn.json` digest) and any `.pmo` cache entries already on disk, keyed by dotted
-- | module name. A module is reused from `loaded` iff it has a source hash, a loaded
-- | entry, and that entry's key equals the freshly computed cache key (source hash ⊕ the
-- | hashes of the dependency summaries it consumed). The filesystem is the caller's
-- | concern — this layer is pure: it consumes loaded entries and reports which to persist.
type CacheInput = { sourceHashes :: Map String String, loaded :: Map String CacheEntry }

-- | A cached module, in memory: the validation key, the finalized MIR (for codegen), and
-- | the pruned summary (for dependents' optimization context). On disk these are split into
-- | `.pmi` (key + deps + summary) and `.pmo` (finalized MIR) — ADR 0034 — but the optimizer
-- | works with the combined record; the file split is the caller's (CLI's) concern.
type CacheEntry = { key :: String, finalMod :: M.Module, summary :: M.Module }

-- | A cache miss to persist: the module's dotted name, its source hash and precise dependency
-- | names (both for the `.pmi`, ADR 0034 — the source hash drives the decode-skip pre-pass), and
-- | the entry itself.
type CacheWrite = { name :: String, sourceHash :: String, deps :: Array String, entry :: CacheEntry }

noCache :: CacheInput
noCache = { sourceHashes: Map.empty, loaded: Map.empty }

-- | `optimizeProgram` with the incremental MIR cache: reuse each module's finalized MIR
-- | from a matching `.pmo` (skipping the expensive specialize/optimize/finalize), and
-- | return the cache *misses* to persist, paired with their dotted module name. A module
-- | with no source hash is never cached, so passing `noCache` reproduces `optimizeProgram`
-- | exactly (the byte-identical gate for this feature).
optimizeProgramCached
  :: Boolean
  -> Set String
  -> Map String Int
  -> CacheInput
  -> Array Module
  -> { modules :: Array M.Module, writes :: Array CacheWrite }
optimizeProgramCached dictElim eff arities cache modules =
  let r = runOpt dictElim eff arities cache Nothing modules in { modules: r.modules, writes: r.writes }

-- | Translate a CoreFn module to MIR and lambda-lift it — the per-module front the incremental
-- | driver (`optimizeIncremental`) runs lazily for a cache miss; `runOpt` does it for every module
-- | up front. Exposed so the CLI can build each `IncInput`'s `lift` thunk.
liftModule :: Module -> M.Module
liftModule m = lambdaLiftModule { name: m.name, decls: map translBind m.decls }

-- | One module's input to the **decode-free** incremental optimizer (ADR 0034). `lift` produces
-- | the translated + lambda-lifted MIR on demand — called only for a cache *miss*, so an unchanged
-- | module is never decoded. `cached` is the loaded `.pmi` (key + precise deps + summary) joined
-- | with the `.pmo` (finalized MIR). `imports` (the corefn import names, cheap to extract) order
-- | the modules without translating. `sourceHash` is the module's `corefn.json` digest.
type IncInput =
  { name :: String
  , imports :: Array String
  , sourceHash :: String
  , cached :: Maybe { key :: String, deps :: Array String, summary :: M.Module, finalMod :: M.Module }
  , lift :: Unit -> M.Module
  }

-- | The dependency-ordered optimizer over **lazy** per-module inputs (ADR 0034): a cache hit
-- | (its key matches the loaded `.pmi`) reuses the finalized + summary MIR and never forces `lift`,
-- | so decode / translate / lambda-lift / optimize are all skipped; a miss forces `lift` and runs
-- | the full per-module pipeline, recording the entry to persist. Order is by corefn imports (a
-- | sound superset of references; modules are acyclic). `summaryInlineKeys` is computed over the
-- | available view — cached summaries plus the lifted form of any module without a cache — a good
-- | approximation (it only widens/narrows which bodies a summary retains for downstream inlining,
-- | never correctness; bench-gated, not byte-identity). The caller (CLI) decides which modules to
-- | decode (a coarse transitive source-unchanged pre-pass) and supplies `lift` only for those.
optimizeIncremental :: Set String -> Map String Int -> Array IncInput -> { modules :: Array M.Module, writes :: Array CacheWrite }
optimizeIncremental eff arities inputs =
  unwrap (optimizeIncrementalM (\_ -> pure unit :: Identity Unit) eff arities inputs)

-- | `optimizeIncremental` over an arbitrary monad, with a per-module progress hook (called once per
-- | module, in dependency order, with its 1-based index, the total, its name, and whether it was a
-- | cache hit) — so the CLI can report live progress (a stage the pure loop could not). The hook
-- | runs *before* the module's work, and the work is forced strictly per step (PureScript is strict),
-- | so the report stays in step with the actual compilation. `optimizeIncremental` is this with a
-- | no-op hook in `Identity`.
optimizeIncrementalM
  :: forall m
   . Monad m
  => ({ index :: Int, total :: Int, name :: String, hit :: Boolean } -> m Unit)
  -> Set String
  -> Map String Int
  -> Array IncInput
  -> m { modules :: Array M.Module, writes :: Array CacheWrite }
optimizeIncrementalM onModule eff arities inputs = do
  result <- foldM step initial ordered
  pure { modules: result.finalized, writes: result.writes }
  where
  names = Set.fromFoldable (map _.name inputs)
  ordered = topoImports inputs
  total = Array.length ordered
  -- A `case` (not `maybe`): the lift fallback must stay unforced for a cached module, since
  -- PureScript is strict and `maybe (i.lift unit) …` would evaluate the thunk eagerly — defeating
  -- the whole decode-free goal (and crashing the test's hit-only `lift`).
  viewOf i = case i.cached of
    Just c -> c.summary
    Nothing -> i.lift unit
  summaryInlineKeys = Set.fromFoldable (Map.keys (buildContext eff Set.empty Set.empty (map viewOf inputs)).inline)

  depHashes :: Array String -> Map String String -> Array String
  depHashes deps sh = Array.mapMaybe (\d -> Map.lookup d sh) deps

  initial = { idx: 0, finalized: [], summaries: [], accCtx: emptyAccum, impure: Set.empty, memEff: Set.empty, summaryHashes: Map.empty, writes: [] }

  step acc i = do
    let
      idx = acc.idx + 1
      hit = case i.cached of
        Just c -> cacheKey i.sourceHash (depHashes c.deps acc.summaryHashes) == c.key
        Nothing -> false
    onModule { index: idx, total, name: i.name, hit }
    pure (apply' acc i hit idx)

  apply' acc i hit idx = case i.cached of
    Just c | hit ->
      acc
        { idx = idx
        , finalized = Array.snoc acc.finalized c.finalMod
        , summaries = Array.snoc acc.summaries c.summary
        , accCtx = mergeAccum acc.accCtx (moduleContribs c.summary)
        , impure = Purity.impureKeys eff acc.impure [ c.summary ]
        , memEff = Purity.memEffKeys acc.memEff [ c.summary ]
        , summaryHashes = Map.insert i.name (hashBytes (encode c.summary)) acc.summaryHashes
        }
    _ ->
      let
        lifted = i.lift unit
        speced = specializeModule acc.summaries lifted
        r = localOpt eff arities acc.accCtx acc.impure acc.memEff speced
        finalMod = finalizeModule eff acc.accCtx acc.summaries r.impure r.memEff r.mod
        summary = DictElim.summarize (Set.unions [ summaryInlineKeys, r.impure, r.memEff, specializationCalleeKeys r.mod ]) r.mod
        deps = referencedModules names lifted
        key = cacheKey i.sourceHash (depHashes deps acc.summaryHashes)
      in
        acc
          { idx = idx
          , finalized = Array.snoc acc.finalized finalMod
          , summaries = Array.snoc acc.summaries summary
          , accCtx = mergeAccum acc.accCtx (moduleContribs summary)
          , impure = r.impure
          , memEff = r.memEff
          , summaryHashes = Map.insert i.name (hashBytes (encode summary)) acc.summaryHashes
          , writes = Array.snoc acc.writes { name: i.name, sourceHash: i.sourceHash, deps, entry: { key, finalMod, summary } }
          }

-- | Order incremental inputs so each comes after the modules it imports (within the input set).
-- | Imports are an acyclic superset of cross-module references, so this is a valid optimization
-- | order computable without translating (unlike `topoOrder`, which needs the lifted MIR).
topoImports :: Array IncInput -> Array IncInput
topoImports inputs = Array.mapMaybe (\n -> Map.lookup n byName) ordered.out
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

-- | The dependency module names a lifted module references (within the known input set): each
-- | reference key is `Module.ident` (ident dotless, `Analysis.key`), so the defining module is the
-- | prefix before the last dot. Restricted to input modules (drops intrinsics / foreigns), matching
-- | the `keyModL` resolution the whole-program path uses.
referencedModules :: Set String -> M.Module -> Array String
referencedModules names m =
  Array.filter (\d -> d /= joinWith "." m.name && Set.member d names)
    (Array.nub (Array.mapMaybe moduleOfKey (declRefs m)))

moduleOfKey :: String -> Maybe String
moduleOfKey k = (\i -> Str.take i k) <$> Str.lastIndexOf (Pattern ".") k

-- | Like `optimizeProgram`, but also returns a human-readable trace of the named module's
-- | MIR — a snapshot after specialization and one after it is optimized (simplify →
-- | impurify → simplify) — for inspecting the optimizer (`purs-wasm --dump-mir`, cf.
-- | purs-backend-es `--trace-rewrites`). The trace is empty unless a target module is given.
optimizeProgramTrace :: Boolean -> Set String -> Map String Int -> String -> Array Module -> Array String
optimizeProgramTrace dictElim eff arities target modules = (runOpt dictElim eff arities noCache (Just target) modules).trace

-- | The whole-program optimizer core. `traceTarget` (a dotted module name) enables the MIR
-- | trace; when `Nothing` the trace stays empty and costs nothing.
runOpt :: Boolean -> Set String -> Map String Int -> CacheInput -> Maybe String -> Array Module -> { modules :: Array M.Module, trace :: Array String, writes :: Array CacheWrite }
runOpt dictElim effectfulForeigns effArities cache traceTarget modules =
  if dictElim then { modules: result.finalized, trace: result.trace <> snap "after post-inline specialization" result.finalized, writes: result.writes }
  else { modules: lifted, trace: snap "initial (translated + lifted)" lifted, writes: [] }
  where
  -- Translate and lambda-lift each module in one step (`liftModule`) rather than materializing
  -- the whole translated-but-unlifted `mir` array first: that intermediate is used nowhere else,
  -- and holding a second full-program MIR copy alongside `lifted` is a real peak-memory cost on a
  -- whole-program build (the `--no-opt` front half holds every module's MIR at once).
  lifted = map liftModule modules

  -- Map a binding key to its defining module, over the lifted program — the same relation
  -- `topoOrder` uses for dependency ordering, reused here to scope a module's cache key to
  -- the dependency summaries it actually consumes (`declRefs`, ADR 0032: output depends only
  -- downward). All deps precede a module in `ordered`, so their summary hashes are known.
  keyModL :: Map String String
  keyModL = Map.fromFoldable (lifted >>= \m -> map (\k -> Tuple k (modName m)) (declKeys m))

  -- A module's cache key and the precise dependency names it was keyed against (recorded in
  -- the `.pmi`, ADR 0034). `Nothing` when the module has no source hash, i.e. is uncacheable.
  keyAndDeps :: String -> M.Module -> Map String String -> Maybe { key :: String, deps :: Array String, src :: String }
  keyAndDeps name m summaryHashes = do
    src <- Map.lookup name cache.sourceHashes
    let deps = Array.filter (_ /= name) (Array.nub (Array.mapMaybe (\k -> Map.lookup k keyModL) (declRefs m)))
    pure { key: cacheKey src (Array.mapMaybe (\d -> Map.lookup d summaryHashes) deps), deps, src }
  -- Higher-order specialization is now per module, inside the loop (`step`), against the
  -- dependency summaries (ADR 0032 caller-homed): the pre-loop whole-program pass is gone.
  -- `topoOrder` is over `lifted` — it counts only non-`$spec` references (a spec imposes no
  -- ordering, `declRefs`), so the order is the same as over the specialized program.
  ordered = topoOrder lifted

  -- The whole-program inline set's keys, computed once over the lifted program: exactly the
  -- bindings any dependent may inline (`DictElim.buildCtx.inline` ∪ general inline candidates). A
  -- finalized dependency's summary must retain these bodies so cross-module inlining — including the
  -- large single-use helpers that expose a `perform` (e.g. `Control.Monad.ap`) — is preserved
  -- regardless of pruning (ADR 0021 b1; guarded by the `DictElim` unit + `EffectPrim` e2e tests).
  -- Specializations are caller-homed (local to the consuming module), so they need not appear here.
  summaryInlineKeys = Set.fromFoldable (Map.keys (buildContext effectfulForeigns Set.empty Set.empty lifted).inline)

  snap :: String -> Array M.Module -> Array String
  snap label prog = case traceTarget of
    Nothing -> []
    Just t ->
      [ "=== " <> label <> " ===\n"
          <> maybe ("(module " <> t <> " not found)") printModule (Array.find (\m -> joinWith "." m.name == t) prog)
      ]

  -- Dependency-ordered optimization (ADR 0021): specialize → optimize → post-inline specialize →
  -- finalize each module once against the already-finalized dependency summaries, never
  -- re-optimizing them. For an acyclic module graph this equals the old whole-program fixed point,
  -- yet it cannot compound — a finalized module is never re-inlined — which is what made the old
  -- N-round whole-program loop blow up on transformer-heavy code.
  -- `finalized` accumulates each module's fully finalized MIR (for codegen); `summaries`
  -- accumulates their *pruned* `localOpt` forms (`DictElim.summarize`) — the context each later
  -- module is specialized/optimized against, so a finalized dependency's large bodies need not stay
  -- resident (ADR 0021 b1). Every pass is per module (ADR 0032 caller-homed specialization), so the
  -- loop yields finalized modules one at a time and there is no whole-program post-pass.
  result = Array.foldl step
    { finalized: [], summaries: [], accCtx: emptyAccum, impure: Set.empty, memEff: Set.empty, trace: [], summaryHashes: Map.empty, writes: [] }
    ordered

  -- A module is a cache hit iff it has a source hash, a loaded `.pmo`, and that entry's
  -- key equals the freshly computed one (source hash ⊕ consumed dependency-summary hashes,
  -- ADR 0032 phase 4). A hit reuses the finalized + summary MIR and skips the expensive
  -- specialize/optimize/finalize; a miss runs the full pipeline and (if the module is
  -- cacheable) records the entry to persist. With no source hash the `Just` guard fails, so
  -- `noCache` takes the miss path for every module — byte-identical to the non-cached build.
  step acc m =
    case keyAndDeps (modName m) m acc.summaryHashes of
      Just kd | Just entry <- Map.lookup (modName m) cache.loaded, entry.key == kd.key -> hitStep acc m entry
      mkd -> missStep acc m mkd

  hitStep acc m entry =
    let
      summary = entry.summary
    in
      { finalized: Array.snoc acc.finalized entry.finalMod
      , summaries: Array.snoc acc.summaries summary
      , accCtx: mergeAccum acc.accCtx (moduleContribs summary)
      -- Purity is re-derived from the cached summary against the *current* seed: the summary
      -- retains all impure / memory-effectful bodies (`DictElim.summarize`), so propagation is
      -- faithful, and a dependency whose effectfulness changed would have changed its summary
      -- hash and thus missed here.
      , impure: Purity.impureKeys effectfulForeigns acc.impure [ summary ]
      , memEff: Purity.memEffKeys acc.memEff [ summary ]
      , trace: acc.trace
      , summaryHashes: Map.insert (modName m) (hashBytes (encode summary)) acc.summaryHashes
      , writes: acc.writes
      }

  missStep acc m mkd =
    let
      speced = specializeModule acc.summaries m
      r = localOpt effectfulForeigns effArities acc.accCtx acc.impure acc.memEff speced
      finalMod = finalizeModule effectfulForeigns acc.accCtx acc.summaries r.impure r.memEff r.mod
      summary = DictElim.summarize (Set.unions [ summaryInlineKeys, r.impure, r.memEff, specializationCalleeKeys r.mod ]) r.mod
    in
      { finalized: Array.snoc acc.finalized finalMod
      -- `summaries` is kept only for `specializeModule`'s candidate-callee lookup; the optimization
      -- context is the incrementally-accumulated `accCtx` (extended by this module's summary).
      , summaries: Array.snoc acc.summaries summary
      , accCtx: mergeAccum acc.accCtx (moduleContribs summary)
      , impure: r.impure
      , memEff: r.memEff
      , trace: case traceTarget of
          Just t | joinWith "." m.name == t -> acc.trace
            <> [ "=== " <> t <> " (specialized) ===\n" <> printModule speced ]
            <> [ "=== " <> t <> " (optimized) ===\n" <> printModule r.mod ]
          _ -> acc.trace
      -- Persist a cacheable miss (one with a source hash, hence a key). The summary hash a
      -- dependent will key against is the same digest whether this module hit or missed.
      , summaryHashes: Map.insert (modName m) (hashBytes (encode summary)) acc.summaryHashes
      , writes: case mkd of
          Just kd -> Array.snoc acc.writes { name: modName m, sourceHash: kd.src, deps: kd.deps, entry: { key: kd.key, finalMod, summary } }
          Nothing -> acc.writes
      }

-- | Build the simplifier context (dictionary elimination + general inlining + purity)
-- | from a set of modules — the finalized dependencies plus the module being optimized.
-- | `seedImpure` / `seedMemEff` are the purity sets already established by finalized dependencies
-- | (ADR 0021 b1). The purity fixpoints start from them, so a dependency pruned to a summary (its
-- | body dropped) still contributes its effectfulness — propagation does not need the dropped body.
-- | Pass `Set.empty` for a from-scratch whole-program build.
buildContext :: Set String -> Set String -> Set String -> Array M.Module -> Ctx
buildContext eff seedImpure seedMemEff prog =
  let
    base = DictElim.buildCtx prog
  in
    base
      { inline = Map.union base.inline (Inline.inlineCandidates prog)
      , newtypeCtors = Set.union base.newtypeCtors (Inline.newtypeCtorNames prog)
      , effectfulForeigns = eff
      , impureBindings = Purity.impureKeys eff seedImpure prog
      , memEffBindings = Purity.memEffKeys seedMemEff prog
      }

emptyAccum :: AccumCtx
emptyAccum = { inline: Map.empty, newtypeCtors: Set.empty, dataCtors: Set.empty, instanceFields: Map.empty }

-- | The inline / constructor / instance-field contributions of one finalized dependency
-- | summary, computed in O(|m|) over *that summary alone* (`DictElim.buildCtx [m]` ∪
-- | `Inline.inlineCandidates [m]`). Per-summary-local — an approximation of the old per-step
-- | whole-program recompute that avoids the O(N²) cost (see the `runOpt` note); correctness-
-- | neutral (only changes *which* small/single-use bodies inline; the global use-count is a knob
-- | a future reduction-aware inliner removes, ADR 0020).
moduleContribs :: M.Module -> AccumCtx
moduleContribs m =
  let
    bc = DictElim.buildCtx [ m ]
  in
    { inline: Map.union bc.inline (Inline.inlineCandidates [ m ])
    , newtypeCtors: Set.union bc.newtypeCtors (Inline.newtypeCtorNames [ m ])
    , dataCtors: bc.dataCtors
    , instanceFields: bc.instanceFields
    }

mergeAccum :: AccumCtx -> AccumCtx -> AccumCtx
mergeAccum a b =
  { inline: Map.union a.inline b.inline
  , newtypeCtors: Set.union a.newtypeCtors b.newtypeCtors
  , dataCtors: Set.union a.dataCtors b.dataCtors
  , instanceFields: Map.union a.instanceFields b.instanceFields
  }

-- | The full simplifier `Ctx` for optimizing `m`: the accumulated dependency context (`accCtx`)
-- | merged with `m`'s *own* context built over `[m]` alone. The own-context uses `buildContext [m]`
-- | rather than the accumulated inline slice so it also picks up `m`'s **local** candidates —
-- | chiefly its caller-homed `$specN` bindings (single-use within `m`) — which must inline
-- | intra-module or they would survive as extra functions. Purity is computed incrementally
-- | (fixpoint over just `m`, seeded by the dependencies' purity).
ctxFromAccum :: Set String -> AccumCtx -> Set String -> Set String -> M.Module -> Ctx
ctxFromAccum eff accCtx seedImpure seedMemEff m =
  let
    own = buildContext eff Set.empty Set.empty [ m ]
  in
    { newtypeCtors: Set.union accCtx.newtypeCtors own.newtypeCtors
    , dataCtors: Set.union accCtx.dataCtors own.dataCtors
    , inline: Map.union accCtx.inline own.inline
    , instanceFields: Map.union accCtx.instanceFields own.instanceFields
    , effectfulForeigns: eff
    , impureBindings: Purity.impureKeys eff seedImpure [ m ]
    , memEffBindings: Purity.memEffKeys seedMemEff [ m ]
    }

-- | One module, optimized once against its finalized dependencies (`accCtx`) plus itself:
-- | simplify (inline + reduce) → impurify (Effect glue → thunks) → simplify again (empty inline
-- | set, to collapse the impurify thunks without re-inlining).
localOpt
  :: Set String
  -> Map String Int
  -> AccumCtx
  -> Set String
  -> Set String
  -> M.Module
  -> { mod :: M.Module, impure :: Set String, memEff :: Set String }
localOpt eff arities accCtx seedImpure seedMemEff m =
  let
    ctx = ctxFromAccum eff accCtx seedImpure seedMemEff m
    simplified = DictElim.simplifyModule ctx m
    impured = fromMaybe simplified (Array.head (impurifyProgram arities [ simplified ]))
  in
    { mod: DictElim.simplifyModule (ctx { inline = Map.empty }) impured
    , impure: ctx.impureBindings
    , memEff: ctx.memEffBindings
    }

-- | Post-inline specialization (ADR 0027), per module (ADR 0032): re-specialize against the
-- | dependency summaries (catching the `where`-worker forwarder that `localOpt` inlined), then a
-- | β/reduce-only simplify (empty inline set) to collapse the residual redexes. Purity is
-- | recomputed incrementally so a new effectful spec's discarded effect is not dropped.
finalizeModule :: Set String -> AccumCtx -> Array M.Module -> Set String -> Set String -> M.Module -> M.Module
finalizeModule eff accCtx deps seedImpure seedMemEff m =
  let
    respec = specializeModule deps m
    ctx = ctxFromAccum eff accCtx seedImpure seedMemEff respec
  in
    DictElim.simplifyModule (ctx { inline = Map.empty }) respec

-- | Order modules so every module comes after the modules it references (a dependency is
-- | finalized before its dependents). Dependencies are taken from actual cross-module
-- | references (CoreFn `Var`s name the *defining* module), not the coarser import list, so
-- | re-export indirection is resolved precisely (ADR 0021). Module imports are acyclic.
topoOrder :: Array M.Module -> Array M.Module
topoOrder prog = Array.mapMaybe (\n -> Map.lookup n byName) (Array.foldl visit { seen: Set.empty, out: [] } (map modName prog)).out
  where
  byName = Map.fromFoldable (map (\m -> Tuple (modName m) m) prog)
  keyMod = Map.fromFoldable (prog >>= \m -> map (\k -> Tuple k (modName m)) (declKeys m))
  depsOf name = case Map.lookup name byName of
    Nothing -> []
    Just m -> Array.filter (_ /= name) (Array.nub (Array.mapMaybe (\k -> Map.lookup k keyMod) (declRefs m)))
  visit acc name
    | Set.member name acc.seen = acc
    | otherwise =
        let
          after = Array.foldl visit (acc { seen = Set.insert name acc.seen }) (depsOf name)
        in
          after { out = Array.snoc after.out name }

modName :: M.Module -> String
modName m = joinWith "." m.name

declKeys :: M.Module -> Array String
declKeys m = m.decls >>= case _ of
  M.NonRec _ i _ -> [ key m.name i ]
  M.Rec rs -> map (\r -> key m.name r.ident) rs

-- | The cross-module references that order a module after its dependencies. A
-- | specialization (`f$specN`) is excluded: `Specialize` places it in the *defining*
-- | module, but its body embeds the *consuming* call site's lambda, so it references the
-- | consuming module. Counting that as the defining module's dependency creates a spurious
-- | defining↔consuming cycle that breaks the acyclic `topoOrder` — leaving the defining
-- | module un-finalized when its consumer is optimized, so the consumer cannot inline it
-- | (the ADR-0018/0019 effect primitives regressed exactly this way: `Effect.Ref.modify$spec0`
-- | references `Examples.EffPrim.Main.add`). A spec imposes no ordering on its defining
-- | module; its consuming-module references are resolved when the consumer inlines it.
declRefs :: M.Module -> Array String
declRefs m = m.decls >>= case _ of
  M.NonRec _ i e -> if isSpec i then [] else references e
  M.Rec rs -> rs >>= \r -> if isSpec r.ident then [] else references r.expr
  where
  isSpec i = contains (Pattern "$spec") i

-- | Optimize a single self-contained module (its own bindings only). A convenience
-- | for callers with one module; cross-module dictionary elimination needs
-- | `optimizeProgram` over all linked modules.
optimizeModule :: Module -> M.Module
optimizeModule m = fromMaybe { name: m.name, decls: [] } (Array.head (optimizeProgram true Set.empty Map.empty [ m ]))

-- | Inputs to optimize ONE module in isolation (ADR 0038 Phase B — the `purwc` worker): the
-- | target's translated + lambda-lifted MIR (`liftModule`), its `corefn.json` source hash, and its
-- | transitive dependencies' `.pmi` summaries **in topological order** (each after the modules it
-- | imports). The summaries are the necessary-and-sufficient optimization context (ADR 0034) — the
-- | same data a cache hit folds into `accCtx`/`impure`/`memEff` in `optimizeIncrementalM`.
type SingleModuleInput =
  { sourceHash :: String
  , lifted :: M.Module
  , depSummaries :: Array M.Module
  }

-- | The isolated-optimization result: the finalized MIR (the `.pmo` body, for codegen), the pruned
-- | summary (the `.pmi` body, for *this* module's dependents), the precise referenced-dependency
-- | names + cache key (the `.pmi` header), and the impure / memory-effecting key sets.
type SingleModuleOutput =
  { finalMod :: M.Module
  , summary :: M.Module
  , deps :: Array String
  , key :: String
  , impure :: Set String
  , memEff :: Set String
  }

-- | Optimize one module against its dependencies' summaries (ADR 0038 Phase B). Folds the
-- | topo-ordered dep summaries to rebuild the optimization context exactly as
-- | `optimizeIncrementalM`'s cache-hit path does (`mergeAccum (moduleContribs …)` + `Purity.*Keys`),
-- | then runs the per-module miss step verbatim (specialize → `localOpt` → `finalizeModule` →
-- | `DictElim.summarize`). `summaryInlineKeys` is taken over `deps ∪ target` rather than the whole
-- | program; since `summarize` keeps only the target's own bindings, this differs from the batch
-- | result only in which *pure* cross-module bodies the summary retains — an inlining-opportunity
-- | (perf) difference, never a correctness one.
compileModuleMir :: Set String -> Map String Int -> SingleModuleInput -> SingleModuleOutput
compileModuleMir eff arities i =
  let
    folded =
      Array.foldl
        ( \acc s ->
            { accCtx: mergeAccum acc.accCtx (moduleContribs s)
            , impure: Purity.impureKeys eff acc.impure [ s ]
            , memEff: Purity.memEffKeys acc.memEff [ s ]
            }
        )
        { accCtx: emptyAccum, impure: Set.empty, memEff: Set.empty }
        i.depSummaries
    summaryInlineKeys =
      Set.fromFoldable (Map.keys (buildContext eff Set.empty Set.empty (Array.snoc i.depSummaries i.lifted)).inline)
    speced = specializeModule i.depSummaries i.lifted
    r = localOpt eff arities folded.accCtx folded.impure folded.memEff speced
    finalMod = finalizeModule eff folded.accCtx i.depSummaries r.impure r.memEff r.mod
    summary = DictElim.summarize (Set.unions [ summaryInlineKeys, r.impure, r.memEff, specializationCalleeKeys r.mod ]) r.mod
    names = Set.fromFoldable (map modName i.depSummaries)
    summaryHashes = Map.fromFoldable (map (\s -> Tuple (modName s) (hashBytes (encode s))) i.depSummaries)
    deps = referencedModules names i.lifted
    key = cacheKey i.sourceHash (Array.mapMaybe (\d -> Map.lookup d summaryHashes) deps)
  in
    { finalMod, summary, deps, key, impure: r.impure, memEff: r.memEff }
