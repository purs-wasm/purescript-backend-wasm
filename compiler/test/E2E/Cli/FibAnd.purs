-- | CLI-driven e2e (ADR 0031 phase 5) of a self-referential CAF: Fibonacci through a recursive
-- | top-level binding. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.FibAnd`.)
module Test.E2E.Cli.FibAnd (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Self-referential CAF (e2e/cli): Fibonacci -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.FibAnd"))
    $ do
        it "computes Fibonacci through the self-referential CAF (fib 10 = 55)" \inst -> do
          r <- liftEffect (callI32x1 inst "fib" 10)
          r `shouldEqual` 55

        it "computes a larger value (fib 15 = 610)" \inst -> do
          r <- liftEffect (callI32x1 inst "fib" 15)
          r `shouldEqual` 610
