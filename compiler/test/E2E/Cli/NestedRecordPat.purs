-- | CLI-driven e2e (ADR 0031 phase 5) of nested field patterns in record binders (`{ x: Just y }`):
-- | a record field whose sub-binder is a constructor, a literal, another record, or a constructor
-- | wrapping a record. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.NestedRecordPat`.)
module Test.E2E.Cli.NestedRecordPat (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Nested record field patterns (e2e/cli): { x: Just y } etc. -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.NestedRecordPat"))
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
