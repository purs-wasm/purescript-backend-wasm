-- | CLI-driven e2e (ADR 0031 phase 5) of `Data.EuclideanRing` on `Int`: `div`/`mod` (non-negative
-- | remainder, all sign combinations, division-by-zero guard) and `degree`. Built standalone by the
-- | real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeEuclid`.)
module Test.E2E.Cli.PreludeEuclid (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Data.EuclideanRing (e2e/cli): div / mod / degree -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Euclid"))
    $ do
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

        it "guards division by zero (returns 0, no trap)" \inst -> do
          d <- liftEffect (callI32x2 inst "divE" 7 0)
          m <- liftEffect (callI32x2 inst "modE" 7 0)
          [ d, m ] `shouldEqual` [ 0, 0 ]

        it "degree is the absolute value" \inst -> do
          pos <- liftEffect (callI32x1 inst "degreeE" 5)
          neg <- liftEffect (callI32x1 inst "degreeE" (-5))
          zero <- liftEffect (callI32x1 inst "degreeE" 0)
          [ pos, neg, zero ] `shouldEqual` [ 5, 5, 0 ]
