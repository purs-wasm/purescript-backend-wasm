-- | End-to-end guard for the `Data.Int.fromNumberImpl` intrinsic — the private foreign
-- | behind `fromNumber`/`floor`/… that applies the `Just` closure to the truncated Int
-- | (or returns `Nothing`). `roundtrip k = fromMaybe (-1) (fromNumber (toNumber k))` must
-- | recover `k`, exercising the closure application + Int boxing in the intrinsic.
module Test.E2E.IntConv (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Data.Int.fromNumberImpl (e2e): Number -> Maybe Int round-trip"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "IntConv" ] ]
                [ "compiler/test/fixtures/IntConv.corefn.json"
                , "compiler/test/fixtures/Data.Int.corefn.json"
                , "compiler/test/fixtures/Data.Maybe.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Control.Category.corefn.json"
                , "compiler/test/fixtures/Control.Semigroupoid.corefn.json"
                ]
            )
        )
    $ do
        it "recovers the Int through fromNumber (the just closure is applied)" \inst -> do
          liftEffect (callI32x1 inst "roundtrip" 42) >>= (_ `shouldEqual` 42)
          liftEffect (callI32x1 inst "roundtrip" 0) >>= (_ `shouldEqual` 0)
          liftEffect (callI32x1 inst "roundtrip" (-7)) >>= (_ `shouldEqual` (-7))
