-- | Coverage for **nested field patterns in record binders** (the `{ x: Just y }` shape):
-- | a record-pattern field whose sub-binder is itself a constructor, a literal, another
-- | record, or a constructor wrapping a record. The decision-tree compiler splices each
-- | field sub-binder back into the matrix (`Lower.Match.specializeRecord`), so these reduce
-- | to the ordinary constructor/literal/record specializations — compiled to wasm and run.
module Test.E2E.NestedRecordPat (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "nested record field patterns (e2e): `{ x: Just y }` etc. -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "NestedRecordPat" ] ]
                [ "compiler/test/fixtures/NestedRecordPat.corefn.json"
                , "compiler/test/fixtures/Data.Maybe.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                ]
            )
        )
    $ do
        it "a record field with a constructor sub-binder (`{ x: Just v }`) binds v" \inst -> do
          liftEffect (callI32x1 inst "fieldJust" 5) >>= (_ `shouldEqual` 105)
        it "the same record pattern reaching the `Nothing` arm" \inst -> do
          liftEffect (callI32x1 inst "fieldNothing" 8) >>= (_ `shouldEqual` 1008)
        it "a record field with a literal sub-binder (`{ tag: 0 }`)" \inst -> do
          liftEffect (callI32x1 inst "fieldLit" 0) >>= (_ `shouldEqual` 7)
          liftEffect (callI32x1 inst "fieldLit" 3) >>= (_ `shouldEqual` 10)
        it "a nested record-in-record field pattern (`{ outer: { inner } }`)" \inst -> do
          liftEffect (callI32x1 inst "fieldNestedRec" 41) >>= (_ `shouldEqual` 42)
        it "a constructor sub-binder wrapping a record (`{ bx: Just { v } }`)" \inst -> do
          liftEffect (callI32x1 inst "fieldJustRec" 6) >>= (_ `shouldEqual` 12)
