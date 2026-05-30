-- | End-to-end test of the Slice 0 pipeline (scalar `Int` world): a pure
-- | PureScript module of top-level functions and saturated calls compiles to
-- | wasm that runs and computes the right answers. The fixture uses
-- | module-local foreign `Int` primitives mapped to i32 intrinsics.
module Test.E2E.Slice0 (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, callI32x1, callI32x2, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 0 (e2e): scalar Int -> IR -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice0.corefn.json"))
    $ do
        it "double x = addI x x" \inst -> do
          result <- liftEffect (callI32x1 inst "double" 21)
          result `shouldEqual` 42

        it "quad x = double (double x)" \inst -> do
          result <- liftEffect (callI32x1 inst "quad" 21)
          result `shouldEqual` 84

        it "sumOfSquares x y = addI (mulI x x) (mulI y y)" \inst -> do
          result <- liftEffect (callI32x2 inst "sumOfSquares" 3 4)
          result `shouldEqual` 25

        it "five = addI 2 3 (nullary export)" \inst -> do
          result <- liftEffect (callI32x0 inst "five")
          result `shouldEqual` 5
