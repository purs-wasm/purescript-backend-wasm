-- | CLI-driven e2e (ADR 0031 phase 5) of arrays — arrays: an array literal + length, indexing, two
-- | indexes combined as unboxed `Int`s, and a nested array index. Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.Slice4c`.)
module Test.E2E.Cli.Arrays (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Arrays (e2e/cli): arrays -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Arrays"))
    $ do
        it "builds an array literal and measures its length" \inst -> do
          result <- liftEffect (callI32x1 inst "countNums" 0)
          result `shouldEqual` 3

        it "indexes an array" \inst -> do
          a <- liftEffect (callI32x1 inst "nthNum" 0)
          b <- liftEffect (callI32x1 inst "nthNum" 2)
          [ a, b ] `shouldEqual` [ 10, 30 ]

        it "indexes twice and combines the (unboxed Int) elements" \inst -> do
          result <- liftEffect (callI32x1 inst "sumFirstTwo" 0)
          result `shouldEqual` 30

        it "indexes a nested array" \inst -> do
          result <- liftEffect (callI32x1 inst "cell" 0)
          result `shouldEqual` 3
