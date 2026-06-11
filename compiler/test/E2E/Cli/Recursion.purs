-- | CLI-driven e2e (ADR 0031 phase 5) of partial application  of slice 2b —  recursion — partial application & recursion: a partially
-- | applied known function, top-level mutual recursion, a self-recursive local `let`, and a mutually
-- | recursive local `let` (knot-tying). Built standalone by the real `purs-wasm build`. (Migrated from
-- | the legacy corefn-fixture `Test.E2E.Slice2b`.)
module Test.E2E.Cli.Recursion (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Recursion (e2e/cli): partial application & recursion -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Recursion"))
    $ do
        it "applies a partially-applied known function" \inst -> do
          result <- liftEffect (callI32x1 inst "add3of" 8)
          result `shouldEqual` 11

        it "runs top-level mutual recursion" \inst -> do
          result <- liftEffect (callI32x0 inst "even4")
          result `shouldEqual` 1

        it "runs a self-recursive local let-binding" \inst -> do
          result <- liftEffect (callI32x0 inst "count3")
          result `shouldEqual` 3

        it "runs a mutually-recursive local let-binding" \inst -> do
          result <- liftEffect (callI32x0 inst "parityOf5")
          result `shouldEqual` 0
