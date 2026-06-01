-- | End-to-end test of real `Prelude` **`Int` Euclidean division** — the top of
-- | `Int`'s algebraic hierarchy (`Data.EuclideanRing`'s `Int` instance). `div` /
-- | `mod` / `degree` reach the `intDiv` / `intMod` / `intDegree` foreigns through
-- | `euclideanRingInt`, which the backend lowers to the shared `$rt.intDiv` /
-- | `$rt.intMod` / `$rt.intDegree` helpers: a **non-negative remainder** and a
-- | **zero guard** (so it matches `Prelude` and never traps), unlike raw
-- | `i32.div_s` / `i32.rem_s`. `Euclid` is linked with the numeric hierarchy
-- | (`Data.Semiring`/`Ring`/`CommutativeRing`/`EuclideanRing`, ADR 0009).
module Test.E2E.PreludeEuclid (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, callI32x2, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Int Euclidean division (e2e): div / mod / degree -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Euclid" ] ]
                [ "compiler/test/fixtures/Euclid.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.CommutativeRing.corefn.json"
                , "compiler/test/fixtures/Data.EuclideanRing.corefn.json"
                ]
            )
        )
    $ do
        -- The defining identity, exercised across every sign combination:
        -- a = (a `div` b) * b + (a `mod` b), with 0 <= mod < |b|.
        it "div matches floor-style Euclidean quotient for all signs" \inst -> do
          pp <- liftEffect (callI32x2 inst "divE" 7 2)
          np <- liftEffect (callI32x2 inst "divE" (-7) 2)
          pn <- liftEffect (callI32x2 inst "divE" 7 (-2))
          nn <- liftEffect (callI32x2 inst "divE" (-7) (-2))
          exact <- liftEffect (callI32x2 inst "divE" 10 5)
          [ pp, np, pn, nn, exact ] `shouldEqual` [ 3, -4, -3, 4, 2 ]

        it "mod is the non-negative remainder for all signs" \inst -> do
          pp <- liftEffect (callI32x2 inst "modE" 7 2)
          np <- liftEffect (callI32x2 inst "modE" (-7) 2)
          pn <- liftEffect (callI32x2 inst "modE" 7 (-2))
          nn <- liftEffect (callI32x2 inst "modE" (-7) (-2))
          small <- liftEffect (callI32x2 inst "modE" (-1) 3)
          [ pp, np, pn, nn, small ] `shouldEqual` [ 1, 1, 1, 1, 2 ]

        -- div/mod by zero return 0 (Prelude's guard), never trapping.
        it "guards division by zero (returns 0, no trap)" \inst -> do
          d <- liftEffect (callI32x2 inst "divE" 7 0)
          m <- liftEffect (callI32x2 inst "modE" 7 0)
          [ d, m ] `shouldEqual` [ 0, 0 ]

        it "degree is the absolute value" \inst -> do
          pos <- liftEffect (callI32x1 inst "degreeE" 5)
          neg <- liftEffect (callI32x1 inst "degreeE" (-5))
          zero <- liftEffect (callI32x1 inst "degreeE" 0)
          [ pos, neg, zero ] `shouldEqual` [ 5, 5, 0 ]
