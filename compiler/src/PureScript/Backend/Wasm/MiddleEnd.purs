-- | The middle-end (optimization layer) facade: translate each module's CoreFn to
-- | the middle IR (ADR 0005) and apply the optimization passes, yielding MIR that
-- | the backend lowering consumes directly. Optimization is **whole-program**:
-- | dictionary elimination inlines across module boundaries, so the passes run over
-- | all linked modules together rather than one at a time.
-- |
-- | Pipeline: translate → lambda lifting (per module) → dictionary elimination
-- | (whole-program simplification driven by a context built from every module).
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
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (specializeProgram)
import PureScript.Backend.Wasm.MiddleEnd.Print (printModule)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind)
import PureScript.CoreFn (Module)

-- | Translate and optimize a whole program to MIR. Each module's name is kept; only
-- | its top-level bindings are represented (lambda lifting may also prepend lifted
-- | supercombinators).
-- |
-- | Dictionary elimination is run to a whole-program fixed point: each round rebuilds
-- | the inline context from the *current* program and simplifies, because eliminating
-- | a dictionary turns a method binding into a fresh inlinable alias (`add =
-- | Data.Semiring.add(semiringInt)` becomes `add = intAdd`, which the next round
-- | inlines so a use `add(x, y)` is the intrinsic directly).
-- | `dictElim` toggles the dictionary-elimination simplification (run to a fixed
-- | point); lambda lifting always runs, since it is what makes deep tail recursion
-- | run in constant stack (disabling it would overflow). Pass `false` to build an
-- | unoptimized baseline.
optimizeProgram :: Boolean -> Set String -> Map String Int -> Array Module -> Array M.Module
optimizeProgram dictElim eff arities modules = (runOpt dictElim eff arities Nothing modules).modules

-- | Like `optimizeProgram`, but also returns a human-readable trace of how the named
-- | module's MIR changes after every sub-stage (specialize / simplify / impurify) of every
-- | round — for inspecting the optimizer (`bin --trace-mir`, cf. purs-backend-es
-- | `--trace-rewrites`). The trace is empty unless a target module is given.
optimizeProgramTrace :: Boolean -> Set String -> Map String Int -> String -> Array Module -> Array String
optimizeProgramTrace dictElim eff arities target modules = (runOpt dictElim eff arities (Just target) modules).trace

-- | The whole-program optimizer core. `traceTarget` (a dotted module name) enables the MIR
-- | trace; when `Nothing` the trace stays empty and costs nothing.
runOpt :: Boolean -> Set String -> Map String Int -> Maybe String -> Array Module -> { modules :: Array M.Module, trace :: Array String }
runOpt dictElim effectfulForeigns effArities traceTarget modules =
  if dictElim then { modules: result.done, trace: result.trace }
  else { modules: lifted, trace: snap "initial (translated + lifted)" lifted }
  where
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir
  -- Higher-order specialization runs once, whole-program, before the per-module pass:
  -- specializations come from call sites' lambda arguments, which exist pre-simplification.
  specialized = specializeProgram lifted
  ordered = topoOrder specialized

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
  result = Array.foldl step { done: [], trace: snap "initial (specialized)" specialized } ordered

  step acc m =
    let
      m' = localOpt acc.done m
    in
      { done: Array.snoc acc.done m'
      , trace: case traceTarget of
          Just t | joinWith "." m.name == t -> acc.trace <> [ "=== " <> t <> " (optimized) ===\n" <> printModule m' ]
          _ -> acc.trace
      }

  -- One module, optimized once against the finalized dependencies plus itself:
  --   simplify (inline + reduce) → impurify (Effect glue → thunks) → simplify again.
  -- NbE normalizes fully in a single pass, so there is no outer round loop — re-running the
  -- *inlining* pass does not converge, it inline-expands the module further each time (the
  -- non-idempotence that, looped, blew up the old whole-program optimizer). The second
  -- simplify is needed only to collapse the thunks impurify introduces (the pure-`Effect`
  -- / State constant-stack TCE collapse, ADR 0015), which is a set of *local* reductions
  -- (β, perform, Abs-merge, float-lambda-out-of-case); it runs with an **empty inline set**
  -- so it performs that collapse without re-inlining (which would re-expand the module).
  localOpt :: Array M.Module -> M.Module -> M.Module
  localOpt done m =
    let
      ctx = buildContext effectfulForeigns (Array.snoc done m)
      simplified = DictElim.simplifyModule ctx m
      impured = fromMaybe simplified (Array.head (impurifyProgram effArities [ simplified ]))
    in
      DictElim.simplifyModule (ctx { inline = Map.empty }) impured

-- | Build the simplifier context (dictionary elimination + general inlining + purity)
-- | from a set of modules — the finalized dependencies plus the module being optimized.
buildContext :: Set String -> Array M.Module -> Ctx
buildContext eff prog =
  let
    base = DictElim.buildCtx prog
  in
    base
      { inline = Map.union base.inline (Inline.inlineCandidates prog)
      , newtypeCtors = Set.union base.newtypeCtors (Inline.newtypeCtorNames prog)
      , effectfulForeigns = eff
      , impureBindings = Purity.impureKeys eff prog
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
