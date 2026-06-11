-- | CLI-driven e2e (ADR 0031 phase 5) of erased values: building/passing `Data.Unit.unit` (ignored),
-- | and `unsafeCoerce` round-tripping `Int -> Number -> Int` unchanged. Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeErased`.)
module Test.E2E.Cli.PreludeErased (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Erased values (e2e/cli): Unit + unsafeCoerce -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Erased"))
    $ do
        it "builds and passes Data.Unit.unit" \inst -> do
          a <- liftEffect (callI32x1 inst "withUnit" 7)
          b <- liftEffect (callI32x1 inst "withUnit" (-3))
          [ a, b ] `shouldEqual` [ 7, -3 ]

        it "erases unsafeCoerce (round-trips Int -> Number -> Int unchanged)" \inst -> do
          a <- liftEffect (callI32x1 inst "coerceRoundTrip" 42)
          b <- liftEffect (callI32x1 inst "coerceRoundTrip" 0)
          [ a, b ] `shouldEqual` [ 42, 0 ]
