-- | End-to-end test of real `Prelude` **`Data.Bounded`** (`top` / `bottom`).
-- | Unlike the other numeric classes these foreigns are *nullary values*, not
-- | functions (arity 0): `topInt` / `bottomInt` materialize as the `i32` extremes
-- | and `topChar` / `bottomChar` as code points `0xFFFF` / `0`, all boxed as
-- | `$Int`. `Bounded`'s `Ord` superclass drives the `<` checks — `Char` compares
-- | by code point, identical to `Int` (shared `i32` rep), so it reuses `OrdInt`.
-- | `Number`'s `Bounded` (`±Infinity`) is implemented but awaits `Number`'s `Ord`
-- | to link, so it is not exercised here. `Bnd` is linked with `Data.Bounded` plus
-- | `Data.Ord` / `Data.Ordering` / `Data.Eq` (ADR 0009).
module Test.E2E.PreludeBounded (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Bounded (e2e): top / bottom for Int and Char -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Bnd" ] ]
                [ "compiler/test/fixtures/Bnd.corefn.json"
                , "compiler/test/fixtures/Data.Bounded.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                ]
            )
        )
    $ do
        it "Int top / bottom are the i32 extremes" \inst -> do
          t <- liftEffect (callI32x0 inst "topI")
          b <- liftEffect (callI32x0 inst "bottomI")
          [ t, b ] `shouldEqual` [ 2147483647, -2147483648 ]

        it "bottom < top through the Ord superclass (Int and Char)" \inst -> do
          i <- liftEffect (callI32x0 inst "intOrdered")
          c <- liftEffect (callI32x0 inst "charOrdered")
          [ i, c ] `shouldEqual` [ 1, 1 ]
