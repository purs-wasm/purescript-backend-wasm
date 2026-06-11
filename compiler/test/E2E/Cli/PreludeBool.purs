-- | CLI-driven e2e (ADR 0031 phase 5) of `Prelude` Booleans: `&&`/`||`/`not` via the
-- | `HeytingAlgebra Boolean` dictionary. Built standalone by the real `purs-wasm build`. (Migrated
-- | from the legacy corefn-fixture `Test.E2E.PreludeBool`.)
module Test.E2E.Cli.PreludeBool (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x2, callI32x3, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Booleans (e2e/cli): && || not -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Bool"))
    $ do
        it "conjuncts two Booleans with &&" \inst -> do
          yes <- liftEffect (callI32x3 inst "conjf" 5 5 5)
          no <- liftEffect (callI32x3 inst "conjf" 5 5 6)
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        it "disjuncts two Booleans with ||" \inst -> do
          l <- liftEffect (callI32x2 inst "disjf" 0 9)
          r <- liftEffect (callI32x2 inst "disjf" 9 0)
          n <- liftEffect (callI32x2 inst "disjf" 9 9)
          [ l, r, n ] `shouldEqual` [ 1, 1, 0 ]

        it "negates a Boolean with not" \inst -> do
          t <- liftEffect (callI32x1 inst "negf" 3)
          f <- liftEffect (callI32x1 inst "negf" 0)
          [ t, f ] `shouldEqual` [ 1, 0 ]
