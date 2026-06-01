-- | End-to-end test of real `Prelude` **`Number` as a `Field`** — the top of
-- | `Number`'s algebraic hierarchy (`Field` = `EuclideanRing` + `DivisionRing`).
-- | This needs no new intrinsic: `DivisionRing`'s `recip x = 1.0 / x` lowers
-- | through `Data.DivisionRing.div` (which is `Data.EuclideanRing.div` partially
-- | applied to `euclideanRingNumber`, a CAF) to the existing `numDiv` (`f64.div`),
-- | and `Field` itself is law-only — its instance just bundles the `EuclideanRing`
-- | and `DivisionRing` superclass dictionaries. Exercising a `Field`-constrained
-- | generic at `Number` forces that whole bundle to link (ADR 0009).
module Test.E2E.PreludeField (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, callI32x2, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Number Field (e2e): recip / Field-generic division -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Fld" ] ]
                [ "compiler/test/fixtures/Fld.corefn.json"
                , "compiler/test/fixtures/Data.DivisionRing.corefn.json"
                , "compiler/test/fixtures/Data.Field.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.CommutativeRing.corefn.json"
                , "compiler/test/fixtures/Data.EuclideanRing.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Int.corefn.json"
                ]
            )
        )
    $ do
        -- recip x is 1.0 / x via DivisionRing; checked by recip x * x == 1.0 at
        -- integral x whose reciprocal is exactly representable.
        it "recip is the multiplicative inverse (recip x * x == 1.0)" \inst -> do
          two <- liftEffect (callI32x1 inst "recipOk" 2)
          four <- liftEffect (callI32x1 inst "recipOk" 4)
          negTwo <- liftEffect (callI32x1 inst "recipOk" (-2))
          [ two, four, negTwo ] `shouldEqual` [ 1, 1, 1 ]

        -- fdiv goes through the Field dictionary's EuclideanRing superclass;
        -- checked by (a / b) * b == a.
        it "Field-constrained division links and computes ((a/b)*b == a)" \inst -> do
          x <- liftEffect (callI32x2 inst "fdivOk" 10 4)
          y <- liftEffect (callI32x2 inst "fdivOk" 9 3)
          [ x, y ] `shouldEqual` [ 1, 1 ]
