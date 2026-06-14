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
  , optimizeProgramTrace
  , optimizeModule
  , CacheInput
  , CacheEntry
  , CacheWrite
  , noCache
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith, contains, Pattern(..))
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

-- | A cache miss to persist: the module's dotted name, its precise dependency names (for the
-- | `.pmi`), and the entry itself.
type CacheWrite = { name :: String, deps :: Array String, entry :: CacheEntry }

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
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir

  -- Map a binding key to its defining module, over the lifted program — the same relation
  -- `topoOrder` uses for dependency ordering, reused here to scope a module's cache key to
  -- the dependency summaries it actually consumes (`declRefs`, ADR 0032: output depends only
  -- downward). All deps precede a module in `ordered`, so their summary hashes are known.
  keyModL :: Map String String
  keyModL = Map.fromFoldable (lifted >>= \m -> map (\k -> Tuple k (modName m)) (declKeys m))

  -- A module's cache key and the precise dependency names it was keyed against (recorded in
  -- the `.pmi`, ADR 0034). `Nothing` when the module has no source hash, i.e. is uncacheable.
  keyAndDeps :: String -> M.Module -> Map String String -> Maybe { key :: String, deps :: Array String }
  keyAndDeps name m summaryHashes = do
    src <- Map.lookup name cache.sourceHashes
    let deps = Array.filter (_ /= name) (Array.nub (Array.mapMaybe (\k -> Map.lookup k keyModL) (declRefs m)))
    pure { key: cacheKey src (Array.mapMaybe (\d -> Map.lookup d summaryHashes) deps), deps }
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
          Just kd -> Array.snoc acc.writes { name: modName m, deps: kd.deps, entry: { key: kd.key, finalMod, summary } }
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
