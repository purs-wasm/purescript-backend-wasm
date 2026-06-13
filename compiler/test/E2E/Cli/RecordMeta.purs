-- | CLI-driven e2e (ADR 0031 phase 5) of record metaprogramming: `RowToList` field iteration and
-- | adding a field whose name has no compile-time id (the runtime label-interning fallback,
-- | `$rt.internDynamic`). Built standalone by the real `purs-wasm build`. Regression guard for the
-- | fix to the `internStr`-`unreachable` gap — adding such a field used to trap.
module Test.E2E.Cli.RecordMeta (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Record metaprogramming (e2e/cli): RowToList + dynamic field insert -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.RecordMeta"))
    $ do
        it "folds a record's fields with RowToList + reflectSymbol + unsafeGet" \inst -> do
          n <- liftEffect (callI32x1 inst "sumFields" 0)
          n `shouldEqual` 10

        it "adds a field whose name has no compile-time id (runtime intern) and reads it back" \inst -> do
          n <- liftEffect (callI32x1 inst "insertField" 0)
          n `shouldEqual` 42

        it "RowList-folds a record grown by a dynamically-named insert (new + old fields)" \inst -> do
          n <- liftEffect (callI32x1 inst "insertThenSum" 0)
          n `shouldEqual` 103
