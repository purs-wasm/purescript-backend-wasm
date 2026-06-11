-- | CLI-driven e2e (ADR 0031 phase 5) of real `Prelude` arithmetic: `E2E.Arith` uses `+`/`*`/`-` on
-- | `Int`, desugaring through the `Semiring`/`Ring` dictionaries down to the `intAdd`/`intMul`/`intSub`
-- | intrinsics. Built standalone by the real `purs-wasm build` and run here. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.PreludeArith`.)
module Test.E2E.Cli.PreludeArith (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude arithmetic (e2e/cli): + * - via dictionaries -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Arith"))
    $ do
        it "computes a * a + b * b through the Semiring dictionary" \inst -> do
          result <- liftEffect (callI32x2 inst "sumSquares" 3 4)
          result `shouldEqual` 25

        it "computes a - b through the Ring dictionary" \inst -> do
          result <- liftEffect (callI32x2 inst "diff" 10 3)
          result `shouldEqual` 7

        it "computes a mixed +/*/- expression" \inst -> do
          a <- liftEffect (callI32x2 inst "poly" 3 4)
          b <- liftEffect (callI32x2 inst "poly" 10 1)
          [ a, b ] `shouldEqual` [ 22, 91 ]
