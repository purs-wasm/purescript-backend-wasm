-- | End-to-end test of real `Prelude` **`Eq` / `Ord`** on `Int`. `==` goes
-- | through the `Eq` dictionary's `eqIntImpl` (→ `i32.eq`); `<` and `compare` go
-- | through the `Ord` dictionary, where `compare` is `ordIntImpl LT EQ GT` — an
-- | intrinsic that selects the `Ordering` ADT (`LT`/`EQ`/`GT`) by a signed `i32`
-- | comparison — and `<` derives from it via a constructor match with a catch-all.
-- | `Cmp` is linked with `Data.Eq` / `Data.Ord` / `Data.Ordering` (ADR 0009).
module Test.E2E.PreludeCompare (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x2, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Eq/Ord (e2e): == < compare via dictionaries -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Cmp" ] ]
                [ "compiler/test/fixtures/Cmp.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                ]
            )
        )
    $ do
        -- isEq a b = if a == b then 1 else 0
        it "compares for equality through the Eq dictionary" \inst -> do
          eq <- liftEffect (callI32x2 inst "isEq" 5 5)
          ne <- liftEffect (callI32x2 inst "isEq" 5 6)
          [ eq, ne ] `shouldEqual` [ 1, 0 ]

        -- isLt a b = if a < b then 1 else 0
        it "compares for less-than (compare + Ordering match with a catch-all)" \inst -> do
          lt <- liftEffect (callI32x2 inst "isLt" 3 7)
          gt <- liftEffect (callI32x2 inst "isLt" 7 3)
          eq <- liftEffect (callI32x2 inst "isLt" 5 5)
          [ lt, gt, eq ] `shouldEqual` [ 1, 0, 0 ]

        -- cmp a b = case compare a b of LT -> 0; EQ -> 1; GT -> 2
        it "returns and matches the Ordering of compare" \inst -> do
          lt <- liftEffect (callI32x2 inst "cmp" 3 7)
          eq <- liftEffect (callI32x2 inst "cmp" 5 5)
          gt <- liftEffect (callI32x2 inst "cmp" 9 2)
          [ lt, eq, gt ] `shouldEqual` [ 0, 1, 2 ]
