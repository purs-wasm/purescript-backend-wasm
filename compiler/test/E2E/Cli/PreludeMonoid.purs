-- | CLI-driven e2e (ADR 0031 phase 5) of `Monoid`: `mempty` (empty `String`/`Array`, left identity)
-- | and the `Additive`/`Multiplicative` newtypes (`<>` sums/multiplies, `mempty` is 0/1). Built
-- | standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture
-- | `Test.E2E.PreludeMonoid`.)
module Test.E2E.Cli.PreludeMonoid (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Monoid (e2e/cli): mempty + Additive/Multiplicative -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Mon"))
    $ do
        it "mempty is the empty String / Array, and is a left identity for <>" \inst -> do
          sLen <- liftEffect (callI32x0 inst "memptyStrLen")
          leftId <- liftEffect (callI32x0 inst "memptyLeftId")
          aLen <- liftEffect (callI32x0 inst "memptyArrLen")
          [ sLen, leftId, aLen ] `shouldEqual` [ 0, 1, 0 ]

        it "Additive monoid: <> sums and mempty is 0" \inst -> do
          s <- liftEffect (callI32x2 inst "addM" 3 4)
          z <- liftEffect (callI32x0 inst "memptyAdd")
          [ s, z ] `shouldEqual` [ 7, 0 ]

        it "Multiplicative monoid: <> multiplies and mempty is 1" \inst -> do
          p <- liftEffect (callI32x2 inst "mulM" 5 6)
          o <- liftEffect (callI32x0 inst "memptyMul")
          [ p, o ] `shouldEqual` [ 30, 1 ]
