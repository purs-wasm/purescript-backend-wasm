-- | CLI-driven e2e (ADR 0031 phase 5) of `Bounded`: `Int` `top`/`bottom` are the i32 extremes, and
-- | `bottom < top` through the `Ord` superclass (`Int` and `Char`). Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeBounded`.)
module Test.E2E.Cli.PreludeBounded (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Bounded (e2e/cli): Int top/bottom + Ord superclass -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Bnd"))
    $ do
        it "Int top / bottom are the i32 extremes" \inst -> do
          t <- liftEffect (callI32x0 inst "topI")
          b <- liftEffect (callI32x0 inst "bottomI")
          [ t, b ] `shouldEqual` [ 2147483647, -2147483648 ]

        it "bottom < top through the Ord superclass (Int and Char)" \inst -> do
          i <- liftEffect (callI32x0 inst "intOrdered")
          c <- liftEffect (callI32x0 inst "charOrdered")
          [ i, c ] `shouldEqual` [ 1, 1 ]
