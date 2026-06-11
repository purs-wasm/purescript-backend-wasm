-- | CLI-driven e2e (ADR 0031 phase 5) of `Field`/`DivisionRing`: `recip` (multiplicative inverse) and
-- | `Field`-constrained division through the `EuclideanRing` superclass, checked by `recip x * x == 1`
-- | and `(a/b)*b == a`. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.PreludeField`.)
module Test.E2E.Cli.PreludeField (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Field / DivisionRing (e2e/cli): recip + Field division -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Fld"))
    $ do
        it "recip is the multiplicative inverse (recip x * x == 1.0)" \inst -> do
          two <- liftEffect (callI32x1 inst "recipOk" 2)
          four <- liftEffect (callI32x1 inst "recipOk" 4)
          negTwo <- liftEffect (callI32x1 inst "recipOk" (-2))
          [ two, four, negTwo ] `shouldEqual` [ 1, 1, 1 ]

        it "Field-constrained division links and computes ((a/b)*b == a)" \inst -> do
          x <- liftEffect (callI32x2 inst "fdivOk" 10 4)
          y <- liftEffect (callI32x2 inst "fdivOk" 9 3)
          [ x, y ] `shouldEqual` [ 1, 1 ]
