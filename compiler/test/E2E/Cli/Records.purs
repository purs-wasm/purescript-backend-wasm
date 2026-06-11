-- | CLI-driven e2e (ADR 0031 phase 5) of general records: construction, field access, update (new
-- | value for the updated field, copy for untouched ones), and pattern destructuring — over the
-- | label-map record machinery (ADR 0001/0007). Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.Records`.)
module Test.E2E.Cli.Records (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Records (e2e/cli): construct / access / update / pattern -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Records"))
    $ do
        it "constructs a record and projects a field" \inst -> do
          result <- liftEffect (callI32x1 inst "getX" 7)
          result `shouldEqual` 7

        it "projects two fields" \inst -> do
          result <- liftEffect (callI32x1 inst "sumXY" 7)
          result `shouldEqual` 15

        it "reads an updated field after a record update" \inst -> do
          result <- liftEffect (callI32x1 inst "updatedX" 7)
          result `shouldEqual` 12

        it "copies untouched fields through a record update" \inst -> do
          result <- liftEffect (callI32x1 inst "keptY" 7)
          result `shouldEqual` 100

        it "destructures a record pattern" \inst -> do
          result <- liftEffect (callI32x1 inst "patX" 7)
          result `shouldEqual` 7
