-- | CLI-driven e2e (ADR 0031 phase 5) of `Eq`/`Ord` on `Int`: `==`, `<`, and `compare` with an
-- | `Ordering` match. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.PreludeCompare`.)
module Test.E2E.Cli.PreludeCompare (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Eq/Ord on Int (e2e/cli): == < compare -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Cmp"))
    $ do
        it "compares for equality through the Eq dictionary" \inst -> do
          eq <- liftEffect (callI32x2 inst "isEq" 5 5)
          ne <- liftEffect (callI32x2 inst "isEq" 5 6)
          [ eq, ne ] `shouldEqual` [ 1, 0 ]

        it "compares for less-than (compare + Ordering match with a catch-all)" \inst -> do
          lt <- liftEffect (callI32x2 inst "isLt" 3 7)
          gt <- liftEffect (callI32x2 inst "isLt" 7 3)
          eq <- liftEffect (callI32x2 inst "isLt" 5 5)
          [ lt, gt, eq ] `shouldEqual` [ 1, 0, 0 ]

        it "returns and matches the Ordering of compare" \inst -> do
          lt <- liftEffect (callI32x2 inst "cmp" 3 7)
          eq <- liftEffect (callI32x2 inst "cmp" 5 5)
          gt <- liftEffect (callI32x2 inst "cmp" 9 2)
          [ lt, eq, gt ] `shouldEqual` [ 0, 1, 2 ]
