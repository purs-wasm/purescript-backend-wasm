-- | End-to-end test that the **record type-class instances** work — `Eq (Record r)`
-- | and `Show (Record r)` from `Data.Eq` / `Data.Show`. These iterate the row with
-- | `reflectSymbol` (the label string) and `Record.Unsafe.unsafeGet` (the value),
-- | so they exercise the whole string-keyed access path end to end: a real record
-- | `==` and `show` lowered to wasm.
module Test.E2E.RecordInstances (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Record instances (e2e): Eq / Show on records -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "RecInst" ] ]
                [ "compiler/test/fixtures/RecInst.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Show.corefn.json"
                , "compiler/test/fixtures/Data.Symbol.corefn.json"
                , "compiler/test/fixtures/Type.Proxy.corefn.json"
                , "compiler/test/fixtures/Data.Semigroup.corefn.json"
                , "compiler/test/fixtures/Data.HeytingAlgebra.corefn.json"
                ]
            )
        )
    $ do
        it "compares records field-by-field with the derived Eq instance" \inst -> do
          yes <- liftEffect (callI32x0 inst "eqYes")
          no <- liftEffect (callI32x0 inst "eqNo")
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        it "renders a record with the Show instance (reflectSymbol labels + unsafeGet)" \inst -> do
          ok <- liftEffect (callI32x0 inst "showP") -- show { x: 1, y: 2 } == "{ x: 1, y: 2 }"
          ok `shouldEqual` 1
