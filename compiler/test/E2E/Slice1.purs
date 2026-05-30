-- | End-to-end test of the Slice 1 pipeline (ADTs + pattern matching): the
-- | fixture builds and matches `OptInt` / `Triple` values internally and exposes
-- | `i32 -> i32` entry points, so the whole boxing + GC + decision-tree path is
-- | exercised through running wasm.
module Test.E2E.Slice1 (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, callI32x3, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 1 (e2e): ADTs + pattern matching -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice1.corefn.json"))
    $ do
        -- someOrElse n = orElse (Some n) 0  -- builds Some, matches the Some arm
        it "matches a field constructor and projects its field" \inst -> do
          result <- liftEffect (callI32x1 inst "someOrElse" 5)
          result `shouldEqual` 5

        -- noneOrElse d = orElse None d  -- builds the nullary None, matches its arm
        it "matches a nullary constructor" \inst -> do
          result <- liftEffect (callI32x1 inst "noneOrElse" 7)
          result `shouldEqual` 7

        -- third a b c = case Triple a b c of Triple _ _ z -> z  -- multi-field + wildcards
        it "builds a multi-field constructor and projects past wildcards" \inst -> do
          result <- liftEffect (callI32x3 inst "third" 1 2 3)
          result `shouldEqual` 3
