-- | End-to-end test for the Slice 2 completion features: partial application
-- | (first-class functions / PAP) and top-level mutual recursion, both compiled
-- | to wasm and run. Recursion terminates structurally on `Nat`.
module Test.E2E.Slice2b (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, callI32x1, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 2 (e2e): partial application & top-level recursion"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice2b.corefn.json"))
    $ do
        -- add3 = addN 3 (partial); add3of n = add3 n (over-applies the nullary value)
        it "applies a partially-applied known function" \inst -> do
          result <- liftEffect (callI32x1 inst "add3of" 8)
          result `shouldEqual` 11

        -- even4 = isEvenN (S (S (S (S Z)))), via the top-level Rec group isEvenN/isOddN
        it "runs top-level mutual recursion" \inst -> do
          result <- liftEffect (callI32x0 inst "even4")
          result `shouldEqual` 1

        -- count3 = countN (S (S (S Z))), via a self-recursive local `let rec go`
        it "runs a self-recursive local let-binding" \inst -> do
          result <- liftEffect (callI32x0 inst "count3")
          result `shouldEqual` 3

        -- parityOf5 = parity 5, via mutually-recursive local `let rec ev/od` (knot-tying)
        it "runs a mutually-recursive local let-binding" \inst -> do
          result <- liftEffect (callI32x0 inst "parityOf5")
          result `shouldEqual` 0
