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
  , optimizeModule
  ) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Set as Set
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim as DictElim
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Inline as Inline
import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (specializeProgram)
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
optimizeProgram :: Boolean -> Array Module -> Array M.Module
optimizeProgram dictElim modules =
  if dictElim then fixpoint maxRounds lifted else lifted
  where
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir

  -- each round: specialize higher-order calls (idempotent once rewritten), then run
  -- the simplifier (dictionary elimination + beta etc.), which inlines the
  -- specialization's lambda body and saturates its operations
  fixpoint :: Int -> Array M.Module -> Array M.Module
  fixpoint n prog
    | n <= 0 = prog
    | otherwise =
        let
          specialized = specializeProgram prog
          -- the dictionary-elimination context, augmented with general known-function
          -- inlining (ordinary small / single-use, acyclic top-level bindings) and
          -- user newtype transparency, all driving the same simplifier (ADR 0005)
          base = DictElim.buildCtx specialized
          ctx = base
            { inline = Map.union base.inline (Inline.inlineCandidates specialized)
            , newtypeCtors = Set.union base.newtypeCtors (Inline.newtypeCtorNames specialized)
            }
          prog' = map (DictElim.simplifyModule ctx) specialized
        in
          if prog' == prog then prog else fixpoint (n - 1) prog'

-- | A generous ceiling on whole-program simplification rounds; dictionary
-- | elimination converges in a few, this only bounds pathological cases.
maxRounds :: Int
maxRounds = 8

-- | Optimize a single self-contained module (its own bindings only). A convenience
-- | for callers with one module; cross-module dictionary elimination needs
-- | `optimizeProgram` over all linked modules.
optimizeModule :: Module -> M.Module
optimizeModule m = fromMaybe { name: m.name, decls: [] } (Array.head (optimizeProgram true [ m ]))
