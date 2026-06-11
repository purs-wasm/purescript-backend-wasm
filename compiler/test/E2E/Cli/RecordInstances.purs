-- | CLI-driven e2e (ADR 0031 phase 5) of record type-class instances: derived `Eq` (field-by-field)
-- | and `Show` (`reflectSymbol` labels + `unsafeGet`). Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.RecordInstances`.)
module Test.E2E.Cli.RecordInstances (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Record instances (e2e/cli): derived Eq + Show -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.RecInst"))
    $ do
        it "compares records field-by-field with the derived Eq instance" \inst -> do
          yes <- liftEffect (callI32x0 inst "eqYes")
          no <- liftEffect (callI32x0 inst "eqNo")
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        it "renders a record with the Show instance (reflectSymbol labels + unsafeGet)" \inst -> do
          ok <- liftEffect (callI32x0 inst "showP") -- show { x: 1, y: 2 } == "{ x: 1, y: 2 }"
          ok `shouldEqual` 1
