-- | CLI-driven e2e (ADR 0031 phase 5) of host **effectful** FFI (ADR 0015) through the generated
-- | loader: `record`/`tick` are genuine host effects (the bundled `.js` holds module-level state).
-- | `runRec` performs two ordered `record`s and reads the sum back (1+2=3); `getTick` ticks twice and
-- | returns the second (2) — pinning that the purity analysis performs each effect exactly once, in
-- | order. Built by the real `purs-wasm build`. (Migrated from the legacy `Test.E2E.HostEff`.)
module Test.E2E.Cli.ForeignEffect (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Host effectful FFI (e2e/cli): ordered host effects via the loader -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignEffect")
    $ do
        it "performs two ordered host effects, each once (record 1; record 2 => sum 3)" \exp -> do
          r <- liftEffect (callI32x1 exp "runRec" 0)
          r `shouldEqual` 3

        it "performs a host effect that returns a value (tick twice => 2)" \exp -> do
          r <- liftEffect (callI32x1 exp "getTick" 0)
          r `shouldEqual` 2
