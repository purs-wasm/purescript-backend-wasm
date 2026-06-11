-- | CLI-driven e2e (ADR 0031 phase 5) of `Monad` do-notation over `Array`: a do-block desugars to
-- | nested bind + pure (list comprehension), `pure` is a singleton, and a wildcard bind replicates the
-- | continuation. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.PreludeMonad`.)
module Test.E2E.Cli.PreludeMonad (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Array Monad do-notation (e2e/cli): bind / pure -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Mnd"))
    $ do
        it "a do-block desugars to nested bind + pure ([x+y | x<-…, y<-…])" \inst -> do
          ok <- liftEffect (callI32x0 inst "pairsOk")
          ok `shouldEqual` 1

        it "pure is a singleton array" \inst -> do
          ok <- liftEffect (callI32x0 inst "pureOk")
          ok `shouldEqual` 1

        it "a wildcard bind (_ <-) replicates the continuation" \inst -> do
          ok <- liftEffect (callI32x0 inst "replOk")
          ok `shouldEqual` 1
