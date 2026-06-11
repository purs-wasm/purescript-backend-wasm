-- | CLI-driven e2e (ADR 0031 phase 5) of pattern guards: multiple boolean guards sharing an
-- | alternative with fall-through to a catch-all, and a guarded constructor pattern that falls
-- | through a failing guard to a later same-constructor alternative. Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeGuards`.)
module Test.E2E.Cli.PreludeGuards (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Pattern guards (e2e/cli): boolean + constructor fall-through -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Guards"))
    $ do
        it "picks the first satisfied guard, then the catch-all" \inst -> do
          big <- liftEffect (callI32x1 inst "classify" 20)
          small <- liftEffect (callI32x1 inst "classify" 5)
          zero <- liftEffect (callI32x1 inst "classify" 0)
          neg <- liftEffect (callI32x1 inst "classify" (-3))
          [ big, small, zero, neg ] `shouldEqual` [ 2, 1, 0, 0 ]

        it "falls through a failing guard to a later same-constructor alternative" \inst -> do
          held <- liftEffect (callI32x1 inst "unboxPos" 7)
          failed <- liftEffect (callI32x1 inst "unboxPos" (-2))
          atZero <- liftEffect (callI32x1 inst "unboxPos" 0)
          [ held, failed, atZero ] `shouldEqual` [ 7, 0, 0 ]

        it "takes an unguarded constructor alternative directly" \inst -> do
          a <- liftEffect (callI32x1 inst "unboxAny" 9)
          b <- liftEffect (callI32x1 inst "unboxAny" (-4))
          [ a, b ] `shouldEqual` [ 9, -4 ]
