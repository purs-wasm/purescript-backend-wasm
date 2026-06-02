-- | End-to-end test of **`Record.Unsafe`** string-keyed record access:
-- | `unsafeGet` / `unsafeSet` (replace + insert) / `unsafeHas` / `unsafeDelete`.
-- |
-- | The runtime `String` key is resolved to its interned `i32` label id by the
-- | emitted `internStr` (the program's label table as a `strEq` chain), then the
-- | id-keyed runtime helpers read or rebuild the record's sorted parallel arrays.
-- | The foreigns are intrinsics, so only `Rec` itself is linked.
module Test.E2E.RecordUnsafe (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Record.Unsafe (e2e): string-keyed record access -> wasm -> run"
    $ before (liftEffect (instantiateLinked [ [ "Rec" ] ] [ "compiler/test/fixtures/Rec.corefn.json" ]))
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
