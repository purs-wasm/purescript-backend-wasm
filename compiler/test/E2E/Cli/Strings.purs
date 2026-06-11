-- | CLI-driven e2e (ADR 0031 phase 5) of strings — strings: concatenation + UTF-8 byte length, byte
-- | equality, a string literal pattern, and multibyte code points (byte length, not code units). Built
-- | standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.Slice4b`.)
module Test.E2E.Cli.Strings (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Strings (e2e/cli): strings -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Strings"))
    $ do
        it "concatenates string literals and measures the UTF-8 byte length" \inst -> do
          result <- liftEffect (callI32x1 inst "greetingLen" 0)
          result `shouldEqual` 13

        it "compares strings for byte equality" \inst -> do
          yes <- liftEffect (callI32x1 inst "eqYes" 0)
          no <- liftEffect (callI32x1 inst "eqNo" 0)
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        it "matches a string literal pattern via the equality helper" \inst -> do
          result <- liftEffect (callI32x1 inst "matchHi" 0)
          result `shouldEqual` 1

        it "encodes multibyte code points as UTF-8 (byte length, not code units)" \inst -> do
          result <- liftEffect (callI32x1 inst "multibyteLen" 0)
          result `shouldEqual` 4
