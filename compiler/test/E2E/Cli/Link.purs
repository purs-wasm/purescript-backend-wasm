-- | CLI-driven e2e (ADR 0031 phase 5) of cross-module linking: `E2E.LinkA` calls a function and
-- | constructs/projects an ADT defined in `E2E.LinkB`. The real `purs-wasm build` resolves the closure
-- | across both modules into one wasm. (Migrated from the legacy corefn-fixture `Test.E2E.Link`.)
module Test.E2E.Cli.Link (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Cross-module linking (e2e/cli): call + ADT across modules -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.LinkA"))
    $ do
        it "calls a function defined in another module" \inst -> do
          result <- liftEffect (callI32x1 inst "quadruple" 5)
          result `shouldEqual` 20

        it "constructs and projects an ADT defined in another module" \inst -> do
          result <- liftEffect (callI32x1 inst "firstOfPair" 7)
          result `shouldEqual` 7
