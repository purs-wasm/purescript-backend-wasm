-- | CLI-driven e2e (ADR 0031 phase 5) of `Data.Ord.Generic.genericCompare` (ordering across and
-- | within constructors) and `Data.Show.Generic.genericShow` (nullary / single-field / product, incl.
-- | a negative field) — exercising the ulib `Data.Show.Generic` foreign through the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeGenericShowCompare`.)
module Test.E2E.Cli.PreludeGenericShowCompare (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "genericCompare / genericShow (e2e/cli) -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.GenSC"))
    $ do
        it "genericCompare orders across and within constructors" \inst -> do
          ab <- liftEffect (callI32x0 inst "cmpAB")
          ba <- liftEffect (callI32x0 inst "cmpBA")
          bblt <- liftEffect (callI32x0 inst "cmpBBlt")
          bbeq <- liftEffect (callI32x0 inst "cmpBBeq")
          cclt <- liftEffect (callI32x0 inst "cmpCClt")
          cceq <- liftEffect (callI32x0 inst "cmpCCeq")
          [ ab, ba, bblt, bbeq, cclt, cceq ] `shouldEqual` [ 0, 2, 0, 1, 0, 1 ]

        it "genericShow renders nullary, single-field, and product constructors" \inst -> do
          a <- liftEffect (callI32x0 inst "showA")
          b <- liftEffect (callI32x0 inst "showB")
          c <- liftEffect (callI32x0 inst "showC")
          neg <- liftEffect (callI32x0 inst "showNeg")
          [ a, b, c, neg ] `shouldEqual` [ 1, 1, 1, 1 ]
