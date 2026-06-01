-- | End-to-end test that **`Generic`-based deriving** works now that general
-- | (multi-scrutinee) pattern matching compiles to a decision tree. `genericEq`
-- | converts both values to their generic representation (`Sum`/`Product`/`Inl`/
-- | `Inr`/`Constructor`/`Argument`/`NoArguments`) and compares them structurally —
-- | a `case x, y of Inl a, Inl b -> …` over those reps, which is exactly the
-- | multi-constructor multi-scrutinee `case` the new `Lower.Match` compiler handles.
-- | `Gen` is linked with `Data.Generic.Rep` / `Data.Eq.Generic` / `Data.Eq` and
-- | `Data.HeytingAlgebra` (the `&&` joining product fields) (ADR 0009).
module Test.E2E.PreludeGeneric (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Generic (e2e): genericEq over a derived Generic rep -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Gen" ] ]
                [ "compiler/test/fixtures/Gen.corefn.json"
                , "compiler/test/fixtures/Data.Generic.Rep.corefn.json"
                , "compiler/test/fixtures/Data.Eq.Generic.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.HeytingAlgebra.corefn.json"
                ]
            )
        )
    $ do
        it "genericEq matches nullary, single-field, and product constructors" \inst -> do
          aa <- liftEffect (callI32x0 inst "eqAA")
          ab <- liftEffect (callI32x0 inst "eqAB")
          bb <- liftEffect (callI32x0 inst "eqBB")
          bbn <- liftEffect (callI32x0 inst "eqBBneq")
          cc <- liftEffect (callI32x0 inst "eqCC")
          ccn <- liftEffect (callI32x0 inst "eqCCneq")
          [ aa, ab, bb, bbn, cc, ccn ] `shouldEqual` [ 1, 0, 1, 0, 1, 0 ]
