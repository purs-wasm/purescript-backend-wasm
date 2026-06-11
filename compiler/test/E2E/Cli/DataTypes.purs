-- | CLI-driven e2e (ADR 0031 phase 5) of ADTs + pattern matching — ADTs + pattern matching: a field constructor and
-- | projection, a nullary constructor, and a multi-field constructor projected past wildcards. Built
-- | standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.Slice1`.)
module Test.E2E.Cli.DataTypes (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x3, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "DataTypes (e2e/cli): ADTs + pattern matching -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.DataTypes"))
    $ do
        it "matches a field constructor and projects its field" \inst -> do
          result <- liftEffect (callI32x1 inst "someOrElse" 5)
          result `shouldEqual` 5

        it "matches a nullary constructor" \inst -> do
          result <- liftEffect (callI32x1 inst "noneOrElse" 7)
          result `shouldEqual` 7

        it "builds a multi-field constructor and projects past wildcards" \inst -> do
          result <- liftEffect (callI32x3 inst "third" 1 2 3)
          result `shouldEqual` 3
