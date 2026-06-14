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
  , optimizeProgramTrace
  , optimizeModule
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
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (specializeProgram, specializeModule, specializationCalleeKeys)
import PureScript.Backend.Wasm.MiddleEnd.Print (printModule)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind)
import PureScript.CoreFn (Module)

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
optimizeProgram dictElim eff arities modules = (runOpt dictElim eff arities Nothing modules).modules

-- | Like `optimizeProgram`, but also returns a human-readable trace of the named module's
-- | MIR — a snapshot after specialization and one after it is optimized (simplify →
-- | impurify → simplify) — for inspecting the optimizer (`purs-wasm --dump-mir`, cf.
-- | purs-backend-es `--trace-rewrites`). The trace is empty unless a target module is given.
optimizeProgramTrace :: Boolean -> Set String -> Map String Int -> String -> Array Module -> Array String
optimizeProgramTrace dictElim eff arities target modules = (runOpt dictElim eff arities (Just target) modules).trace

-- | The whole-program optimizer core. `traceTarget` (a dotted module name) enables the MIR
-- | trace; when `Nothing` the trace stays empty and costs nothing.
runOpt :: Boolean -> Set String -> Map String Int -> Maybe String -> Array Module -> { modules :: Array M.Module, trace :: Array String }
runOpt dictElim effectfulForeigns effArities traceTarget modules =
  if dictElim then { modules: finalized, trace: result.trace <> snap "after post-inline specialization" finalized }
  else { modules: lifted, trace: snap "initial (translated + lifted)" lifted }
  where
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir
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

  -- Dependency-ordered optimization (ADR 0021): optimize each module once to a local
  -- fixed point against the already-finalized modules (`done`), never re-optimizing them.
  -- For an acyclic module graph this equals the old whole-program fixed point, yet it
  -- cannot compound — a finalized module is never re-inlined — which is what made the old
  -- N-round whole-program loop blow up on transformer-heavy code.
  -- `done` accumulates the fully-optimized modules (kept for post-inline specialization and
  -- codegen); `summaries` accumulates their *pruned* forms (`DictElim.summarize`) — the inline
  -- context each later module is optimized against, so a finalized dependency's large bodies need
  -- not stay resident to inline against (ADR 0021 b1). `buildContext` over the pruned summaries is
  -- equivalent for dictionary elimination (guarded by the cross-module `DictElim` unit test).
  result = Array.foldl step { done: [], summaries: [], impure: Set.empty, memEff: Set.empty, trace: [] } ordered

  -- Post-inline specialization (ADR 0027). The pre-inline `specializeProgram` above misses
  -- the `where`-worker idiom: `foo f = … go … where go … = … f …` lambda-lifts to a
  -- *forwarder* `foo` (passes `f`, never applies it — not a static-arg candidate) and a
  -- *worker* `go$liftN` (applies `f`, but its call sites only ever get the forwarded
  -- variable, never a literal lambda). The per-module `localOpt` then inlines the forwarder,
  -- so the lambda finally lands at the worker's call site — where the (unchanged) specializer
  -- can fuse it. A second `specializeProgram` over the optimized program catches these; a
  -- β/reduce-only simplify (empty inline set, exactly as `localOpt`'s second simplify) then
  -- collapses the `(\… -> …)(…)` redexes the static-argument substitution leaves. This is a
  -- single bounded pass (specialize + reduce, no re-inlining), not a fixed-point loop, so it
  -- cannot reintroduce the whole-program N-round compounding ADR 0021 removed. It must stay
  -- whole-program: the worker is often a *library* `$liftN` (e.g. `Data.Foldable.go$lift1`) whose
  -- concrete lambda only appears at a *consuming* module's call site after that module inlines its
  -- forwarder, so the spec spans a module boundary and a per-module pass would forgo it.
  respecialized = specializeProgram result.done
  reCtx = buildContext effectfulForeigns Set.empty Set.empty respecialized
  finalized = map (\m -> DictElim.simplifyModule (reCtx { inline = Map.empty }) m) respecialized

  step acc m =
    let
      -- per-module pre-inline specialization against the finalized dependency summaries (ADR 0032):
      -- caller-homed, so every spec lands in `m`; the summaries supply the cross-module callee bodies
      -- (kept by `specializationCalleeKeys` below).
      speced = specializeModule acc.summaries m
      r = localOpt acc.impure acc.memEff acc.summaries speced
    in
      { done: Array.snoc acc.done r.mod
      -- the summary keeps, beyond the inline candidates / effectful bindings, this module's
      -- specialization-callee bodies so a *dependent* can specialize them across the boundary
      , summaries: Array.snoc acc.summaries
          (DictElim.summarize (Set.unions [ summaryInlineKeys, r.impure, r.memEff, specializationCalleeKeys r.mod ]) r.mod)
      , impure: r.impure
      , memEff: r.memEff
      , trace: case traceTarget of
          Just t | joinWith "." m.name == t -> acc.trace
            <> [ "=== " <> t <> " (specialized) ===\n" <> printModule speced ]
            <> [ "=== " <> t <> " (optimized) ===\n" <> printModule r.mod ]
          _ -> acc.trace
      }

  -- One module, optimized once against its finalized dependencies (as pruned `summarize`d
  -- modules — ADR 0021 b1) plus itself:
  --   simplify (inline + reduce) → impurify (Effect glue → thunks) → simplify again.
  -- NbE normalizes fully in a single pass, so there is no outer round loop — re-running the
  -- *inlining* pass does not converge, it inline-expands the module further each time (the
  -- non-idempotence that, looped, blew up the old whole-program optimizer). The second
  -- simplify is needed only to collapse the thunks impurify introduces (the pure-`Effect`
  -- / State constant-stack TCE collapse, ADR 0015), which is a set of *local* reductions
  -- (β, perform, Abs-merge, float-lambda-out-of-case); it runs with an **empty inline set**
  -- so it performs that collapse without re-inlining (which would re-expand the module).
  localOpt
    :: Set String
    -> Set String
    -> Array M.Module
    -> M.Module
    -> { mod :: M.Module, impure :: Set String, memEff :: Set String }
  localOpt seedImpure seedMemEff deps m =
    let
      ctx = buildContext effectfulForeigns seedImpure seedMemEff (Array.snoc deps m)
      simplified = DictElim.simplifyModule ctx m
      impured = fromMaybe simplified (Array.head (impurifyProgram effArities [ simplified ]))
    in
      { mod: DictElim.simplifyModule (ctx { inline = Map.empty }) impured
      , impure: ctx.impureBindings
      , memEff: ctx.memEffBindings
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
