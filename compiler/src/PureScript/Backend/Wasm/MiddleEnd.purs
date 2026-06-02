-- | The middle-end (optimization layer) facade: run a module through the middle IR
-- | (ADR 0005) — translate CoreFn to the MIR, apply the optimization passes, and
-- | translate back. Passes run between translation and back-translation, where they
-- | are end-to-end verifiable. Today the only pass is lambda lifting; back on
-- | CoreFn the rest of the lowering is unchanged.
module PureScript.Backend.Wasm.MiddleEnd
  ( optimizeModule
  ) where

import Prelude

import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind)
import PureScript.Backend.Wasm.MiddleEnd.Untransl (untranslBind)
import PureScript.CoreFn (Module)

-- | Run a module's top-level bindings through the MIR optimization passes,
-- | preserving the surrounding module metadata (name, imports, foreign, …). Only
-- | the expression-level bindings are represented in the MIR, so only `decls`
-- | change; lambda lifting may also *prepend* lifted top-level supercombinators.
optimizeModule :: Module -> Module
optimizeModule m =
  m { decls = map untranslBind optimized.decls }
  where
  optimized = lambdaLiftModule { name: m.name, decls: map translBind m.decls }
