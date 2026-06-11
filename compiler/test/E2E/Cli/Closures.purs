-- | CLI-driven e2e (ADR 0031 phase 5) of closures — closures: a capturing lambda created and applied,
-- | passed to a higher-order function, and a multi-argument closure applied via a chain of `call_ref`.
-- | Built standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture
-- | `Test.E2E.Slice2`.)
module Test.E2E.Cli.Closures (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x2, callI32x3, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Closures (e2e/cli): closures -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Closures"))
    $ do
        it "creates and applies a capturing lambda" \inst -> do
          result <- liftEffect (callI32x2 inst "addThruClosure" 3 4)
          result `shouldEqual` 7

        it "passes a capturing lambda to a higher-order function" \inst -> do
          result <- liftEffect (callI32x2 inst "twiceAdd" 10 5)
          result `shouldEqual` 25

        it "applies a multi-argument closure via a chain of call_ref" \inst -> do
          result <- liftEffect (callI32x3 inst "sum3" 1 2 3)
          result `shouldEqual` 6
