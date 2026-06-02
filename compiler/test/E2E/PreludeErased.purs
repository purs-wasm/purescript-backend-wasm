-- | End-to-end test of the **erased foreigns**: `Data.Unit.unit` and
-- | `unsafeCoerce`. `unit` lowers to a never-inspected boxed constant; `unsafeCoerce`
-- | is representation-preserving (values are uniformly `eqref`), so it is erased
-- | during lowering — `unsafeCoerce x` *is* `x`, with no op emitted. `Erased` is
-- | linked with `Data.Function` (`const`) and `Data.Semiring` (`add`).
module Test.E2E.PreludeErased (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude erased foreigns (e2e): unit + unsafeCoerce -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Erased" ] ]
                [ "compiler/test/fixtures/Erased.corefn.json"
                , "compiler/test/fixtures/Data.Function.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                ]
            )
        )
    $ do
        -- withUnit n = const n unit  — `unit` is built and passed but ignored
        it "builds and passes Data.Unit.unit" \inst -> do
          a <- liftEffect (callI32x1 inst "withUnit" 7)
          b <- liftEffect (callI32x1 inst "withUnit" (-3))
          [ a, b ] `shouldEqual` [ 7, -3 ]

        -- coerceRoundTrip n = add (unsafeCoerce (unsafeCoerce n :: Number)) 0 — identity
        it "erases unsafeCoerce (round-trips Int -> Number -> Int unchanged)" \inst -> do
          a <- liftEffect (callI32x1 inst "coerceRoundTrip" 42)
          b <- liftEffect (callI32x1 inst "coerceRoundTrip" 0)
          [ a, b ] `shouldEqual` [ 42, 0 ]
