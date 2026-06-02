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
import Data.Maybe (fromMaybe)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim as DictElim
import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind)
import PureScript.CoreFn (Module)

-- | Translate and optimize a whole program to MIR. Each module's name is kept; only
-- | its top-level bindings are represented (lambda lifting may also prepend lifted
-- | supercombinators).
optimizeProgram :: Array Module -> Array M.Module
optimizeProgram modules = map (DictElim.simplifyModule ctx) lifted
  where
  mir = map (\m -> { name: m.name, decls: map translBind m.decls } :: M.Module) modules
  lifted = map lambdaLiftModule mir
  ctx = DictElim.buildCtx lifted

-- | Optimize a single self-contained module (its own bindings only). A convenience
-- | for callers with one module; cross-module dictionary elimination needs
-- | `optimizeProgram` over all linked modules.
optimizeModule :: Module -> M.Module
optimizeModule m = fromMaybe { name: m.name, decls: [] } (Array.head (optimizeProgram [ m ]))
