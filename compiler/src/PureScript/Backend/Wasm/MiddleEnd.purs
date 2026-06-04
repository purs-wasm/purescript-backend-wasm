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
import Data.String (joinWith)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim as DictElim
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify (impurifyProgram)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Inline as Inline
import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity as Purity
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
  if dictElim then fixpoint maxRounds 1 lifted (snap "initial (translated + lifted)" lifted)
  else { modules: lifted, trace: snap "initial (translated + lifted)" lifted }
  where
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir

  -- a labelled snapshot of the traced module's MIR (empty when not tracing)
  snap :: String -> Array M.Module -> Array String
  snap label prog = case traceTarget of
    Nothing -> []
    Just t ->
      let
        body = maybe ("(module " <> t <> " not found)") printModule
          (Array.find (\m -> joinWith "." m.name == t) prog)
      in
        [ "=== " <> label <> " ===\n" <> body ]

  -- each round: specialize higher-order calls (idempotent once rewritten), then run
  -- the simplifier (dictionary elimination + beta etc.), which inlines the
  -- specialization's lambda body and saturates its operations
  fixpoint :: Int -> Int -> Array M.Module -> Array String -> { modules :: Array M.Module, trace :: Array String }
  fixpoint n r prog trace
    | n <= 0 = { modules: prog, trace }
    | otherwise =
        let
          specialized = specializeProgram prog
          -- the dictionary-elimination context, augmented with general known-function
          -- inlining (ordinary small / single-use, acyclic top-level bindings) and
          -- user newtype transparency, all driving the same simplifier (ADR 0005)
          base = DictElim.buildCtx specialized
          -- whole-program purity (ADR 0015): which top-level bindings are effectful to
          -- run, so the simplifier preserves effectful `Perform`s while still collapsing
          -- pure `Effect` (a binding absent from the set is pure-running)
          impure = Purity.impureKeys effectfulForeigns specialized
          ctx = base
            { inline = Map.union base.inline (Inline.inlineCandidates specialized)
            , newtypeCtors = Set.union base.newtypeCtors (Inline.newtypeCtorNames specialized)
            , effectfulForeigns = effectfulForeigns
            , impureBindings = impure
            }
          -- after dict-elim resolves `bind`/`pure` over `Effect` to the `bindE`/`pureE`
          -- foreigns, impurify rewrites them to the thunk encoding; the next round's
          -- simplifier collapses the resulting lambdas/applications (ADR 0015)
          simplified = map (DictElim.simplifyModule ctx) specialized
          prog' = impurifyProgram effArities simplified
          trace' = trace
            <> snap ("round " <> show r <> " · after specialize") specialized
            <> snap ("round " <> show r <> " · after simplify") simplified
            <> snap ("round " <> show r <> " · after impurify") prog'
        in
          if prog' == prog then { modules: prog, trace: trace' } else fixpoint (n - 1) (r + 1) prog' trace'

-- | A generous ceiling on whole-program simplification rounds; dictionary
-- | elimination converges in a few, this only bounds pathological cases.
maxRounds :: Int
maxRounds = 8

-- | Optimize a single self-contained module (its own bindings only). A convenience
-- | for callers with one module; cross-module dictionary elimination needs
-- | `optimizeProgram` over all linked modules.
optimizeModule :: Module -> M.Module
optimizeModule m = fromMaybe { name: m.name, decls: [] } (Array.head (optimizeProgram true Set.empty Map.empty [ m ]))
