-- | CLI-driven e2e (ADR 0031 phase 5) of `Data.Eq.Generic.genericEq`: across nullary, single-field,
-- | and product constructors. Built standalone by the real `purs-wasm build`. (Migrated from the
-- | legacy corefn-fixture `Test.E2E.PreludeGeneric`.)
module Test.E2E.Cli.PreludeGeneric (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "genericEq (e2e/cli): nullary / single-field / product -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Gen"))
    $ do
        it "genericEq matches nullary, single-field, and product constructors" \inst -> do
          aa <- liftEffect (callI32x0 inst "eqAA")
          ab <- liftEffect (callI32x0 inst "eqAB")
          bb <- liftEffect (callI32x0 inst "eqBB")
          bbn <- liftEffect (callI32x0 inst "eqBBneq")
          cc <- liftEffect (callI32x0 inst "eqCC")
          ccn <- liftEffect (callI32x0 inst "eqCCneq")
          [ aa, ab, bb, bbn, cc, ccn ] `shouldEqual` [ 1, 0, 1, 0, 1, 0 ]
