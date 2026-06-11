-- | CLI-driven e2e (ADR 0031 phase 5) of scalar Int codegen — scalar `Int`: composition, a 2-arg combinator, and
-- | a nullary export. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.Slice0`.)
module Test.E2E.Cli.Scalars (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Scalars (e2e/cli): scalar Int -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Scalars"))
    $ do
        it "double x = addI x x" \inst -> do
          result <- liftEffect (callI32x1 inst "double" 21)
          result `shouldEqual` 42

        it "quad x = double (double x)" \inst -> do
          result <- liftEffect (callI32x1 inst "quad" 21)
          result `shouldEqual` 84

        it "sumOfSquares x y = addI (mulI x x) (mulI y y)" \inst -> do
          result <- liftEffect (callI32x2 inst "sumOfSquares" 3 4)
          result `shouldEqual` 25

        it "five = addI 2 3 (nullary export)" \inst -> do
          result <- liftEffect (callI32x0 inst "five")
          result `shouldEqual` 5
