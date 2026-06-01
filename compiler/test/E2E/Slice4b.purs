-- | End-to-end test of Slice 4b (strings): UTF-8 `$Str = (struct (ref (array
-- | i8)))` literals, the byte-length / concatenation / equality runtime helpers,
-- | and string literal patterns. Strings are built internally and reduced to an
-- | `i32` (a length, a comparison, or a match result) for the host boundary.
module Test.E2E.Slice4b (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 4b (e2e): strings -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice4b.corefn.json"))
    $ do
        -- greetingLen _ = lenS (concatS "Hello, " "world!")  -- concat then byte length
        it "concatenates string literals and measures the UTF-8 byte length" \inst -> do
          result <- liftEffect (callI32x1 inst "greetingLen" 0)
          result `shouldEqual` 13

        -- eqYes/eqNo: string byte-equality of equal and unequal literals
        it "compares strings for byte equality" \inst -> do
          yes <- liftEffect (callI32x1 inst "eqYes" 0)
          no <- liftEffect (callI32x1 inst "eqNo" 0)
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        -- matchHi _ = case concatS "h" "i" of "hi" -> 1; "ho" -> 2; _ -> 0
        it "matches a string literal pattern via the equality helper" \inst -> do
          result <- liftEffect (callI32x1 inst "matchHi" 0)
          result `shouldEqual` 1

        -- multibyteLen _ = lenS "aéb"  -- é encodes to two UTF-8 bytes
        it "encodes multibyte code points as UTF-8 (byte length, not code units)" \inst -> do
          result <- liftEffect (callI32x1 inst "multibyteLen" 0)
          result `shouldEqual` 4
