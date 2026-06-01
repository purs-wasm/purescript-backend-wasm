-- | End-to-end test of real `Prelude` **`Data.Monoid`** (`mempty`) and two of the
-- | newtype monoids (`Additive` / `Multiplicative`). `Data.Monoid` has no foreigns
-- | and needs no new machine op: `mempty` is a nullary class method projected from
-- | the `Monoid` dictionary — `""` for `String`, `[]` for `Array`, `Additive zero`
-- | / `Multiplicative one` for the Semiring-backed newtypes — and the newtype
-- | wrappers erase, so `Additive a <> Additive b` reduces straight through the
-- | existing `Semigroup` / `Semiring` paths. `Mon` is linked with `Data.Monoid`,
-- | `Data.Monoid.Additive` / `Multiplicative`, `Data.Semigroup`, `Data.Semiring`,
-- | and `Data.Eq` (ADR 0009).
module Test.E2E.PreludeMonoid (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, callI32x2, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Monoid (e2e): mempty + Additive / Multiplicative -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Mon" ] ]
                [ "compiler/test/fixtures/Mon.corefn.json"
                , "compiler/test/fixtures/Data.Monoid.corefn.json"
                , "compiler/test/fixtures/Data.Monoid.Additive.corefn.json"
                , "compiler/test/fixtures/Data.Monoid.Multiplicative.corefn.json"
                , "compiler/test/fixtures/Data.Semigroup.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                ]
            )
        )
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
