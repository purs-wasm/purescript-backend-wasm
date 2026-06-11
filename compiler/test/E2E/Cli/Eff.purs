-- | CLI-driven e2e (ADR 0031 phase 5) of Effect impurification (ADR 0015): a pure `Effect` do-block
-- | under `unsafePerformEffect` collapses to plain arithmetic — Functor/Apply/Applicative/Bind, and a
-- | deep bind loop that must run in constant stack. Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.Eff`.)
module Test.E2E.Cli.Eff (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Effect impurification (e2e/cli): pure Effect do-block collapses + runs -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Eff"))
    $ do
        it "runs a pure Effect do-block (bind): runEff n = n + 1" \inst -> do
          r <- liftEffect (callI32x1 inst "runEff" 41)
          r `shouldEqual` 42
          r0 <- liftEffect (callI32x1 inst "runEff" 0)
          r0 `shouldEqual` 1

        it "runs Functor (map) over Effect: mapEff n = n + 1" \inst -> do
          r <- liftEffect (callI32x1 inst "mapEff" 9)
          r `shouldEqual` 10

        it "runs Apply/Applicative over Effect: applyEff a b = a + b" \inst -> do
          r <- liftEffect (callI32x2 inst "applyEff" 3 4)
          r `shouldEqual` 7

        it "runs Bind over Effect: bindEff n = n * 2" \inst -> do
          r <- liftEffect (callI32x1 inst "bindEff" 21)
          r `shouldEqual` 42

        it "runs a deep Effect loop without overflowing (constant stack)" \inst -> do
          r <- liftEffect (callI32x1 inst "countEff" 1000000)
          r `shouldEqual` 1000000
