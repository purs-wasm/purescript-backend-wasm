-- | End-to-end test of the Slice 2 pipeline (closures): a capturing lambda is
-- | created, applied directly, and passed to a higher-order function, all
-- | compiling to wasm that runs — exercising lambda lifting, closure conversion,
-- | and `call_ref` through the running module.
module Test.E2E.Slice2 (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x2, callI32x3, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 2 (e2e): closures -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice2.corefn.json"))
    $ do
        -- addThruClosure a b = (\y -> addI a y) b  -- capture a, apply to b
        it "creates and applies a capturing lambda" \inst -> do
          result <- liftEffect (callI32x2 inst "addThruClosure" 3 4)
          result `shouldEqual` 7

        -- twiceAdd k x = applyTwice (\y -> addI k y) x  -- capture passed to a HOF
        it "passes a capturing lambda to a higher-order function" \inst -> do
          result <- liftEffect (callI32x2 inst "twiceAdd" 10 5)
          result `shouldEqual` 25

        -- sum3 a b c = applyBoth (\x y -> addI (addI a x) y) b c  -- multi-arg apply
        it "applies a multi-argument closure via a chain of call_ref" \inst -> do
          result <- liftEffect (callI32x3 inst "sum3" 1 2 3)
          result `shouldEqual` 6
