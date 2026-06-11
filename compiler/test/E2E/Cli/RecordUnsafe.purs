-- | CLI-driven e2e (ADR 0031 phase 5) of `Record.Unsafe`: `unsafeGet` (read), `unsafeSet` (replace +
-- | insert), and `unsafeHas`/`unsafeDelete` (membership). Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.RecordUnsafe`.)
module Test.E2E.Cli.RecordUnsafe (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Record.Unsafe (e2e/cli): get / set / has / delete -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Rec"))
    $ do
        it "reads fields with unsafeGet" \inst -> do
          foo <- liftEffect (callI32x0 inst "getFoo")
          baz <- liftEffect (callI32x0 inst "getBaz")
          [ foo, baz ] `shouldEqual` [ 10, 30 ]

        it "rebuilds with unsafeSet (replace an existing field and insert a new one)" \inst -> do
          replaced <- liftEffect (callI32x0 inst "setBar")
          inserted <- liftEffect (callI32x0 inst "insBaz")
          [ replaced, inserted ] `shouldEqual` [ 99, 77 ]

        it "tests membership with unsafeHas, before and after unsafeDelete" \inst -> do
          present <- liftEffect (callI32x0 inst "hasFoo")
          deleted <- liftEffect (callI32x0 inst "hasDeleted")
          kept <- liftEffect (callI32x0 inst "hasKept")
          [ present, deleted, kept ] `shouldEqual` [ 1, 0, 1 ]
