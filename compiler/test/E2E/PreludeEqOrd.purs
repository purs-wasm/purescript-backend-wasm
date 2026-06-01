-- | End-to-end test of the extended real `Prelude` **`Eq` / `Ord`** instances:
-- | `Boolean` equality/ordering and `Number` ordering. `eqBooleanImpl` →
-- | `BoolEq` (compare the `i31` bits); `ordBooleanImpl` / `ordNumberImpl` share the
-- | `lt eq gt x y` five-operand `unsafeCompareImpl` shape with `ordIntImpl`,
-- | differing only in the unbox + compare (`i31` / `f64`). `EqOrd` is linked with
-- | `Data.Eq` / `Data.Ord` / `Data.Ordering` (ADR 0009).
module Test.E2E.PreludeEqOrd (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Eq/Ord (e2e): Boolean ==/<, Number Ord -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "EqOrd" ] ]
                [ "compiler/test/fixtures/EqOrd.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                , "compiler/test/fixtures/Data.HeytingAlgebra.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                ]
            )
        )
    $ do
        it "Boolean equality (true == true, true /= false)" \inst -> do
          tt <- liftEffect (callI32x0 inst "boolEqTT")
          tf <- liftEffect (callI32x0 inst "boolEqTF")
          [ tt, tf ] `shouldEqual` [ 1, 0 ]

        it "Boolean ordering (false < true, not true < false, true >= true)" \inst -> do
          ft <- liftEffect (callI32x0 inst "boolLtFT")
          tf <- liftEffect (callI32x0 inst "boolLtTF")
          ge <- liftEffect (callI32x0 inst "boolGeTT")
          [ ft, tf, ge ] `shouldEqual` [ 1, 0, 1 ]

        it "Number ordering covers the lt / eq / gt branches" \inst -> do
          lt <- liftEffect (callI32x0 inst "numLt")
          gt <- liftEffect (callI32x0 inst "numGt")
          ge <- liftEffect (callI32x0 inst "numGeEq")
          le <- liftEffect (callI32x0 inst "numLeFalse")
          [ lt, gt, ge, le ] `shouldEqual` [ 1, 1, 1, 0 ]

        it "String ordering is lexicographic (incl. prefix < longer)" \inst -> do
          lt <- liftEffect (callI32x0 inst "strLt")
          pre <- liftEffect (callI32x0 inst "strPrefix")
          ge <- liftEffect (callI32x0 inst "strGe")
          [ lt, pre, ge ] `shouldEqual` [ 1, 1, 1 ]

        -- A single-constructor `derive instance Eq` compiles to a single-alternative
        -- two-scrutinee `case` (the `nestColumns` path), comparing each field. (A
        -- *multi*-constructor derived Eq/Ord needs column-wise decision-tree pattern
        -- compilation, which is a separate, not-yet-implemented feature.)
        it "derived Eq on a single-constructor ADT compares its fields" \inst -> do
          peq <- liftEffect (callI32x0 inst "pairEq")
          pneq <- liftEffect (callI32x0 inst "pairNeq")
          [ peq, pneq ] `shouldEqual` [ 1, 0 ]

        it "Array equality (length check + element-wise, Int and String)" \inst -> do
          eq <- liftEffect (callI32x0 inst "arrEq")
          neq <- liftEffect (callI32x0 inst "arrNeq")
          lenN <- liftEffect (callI32x0 inst "arrLenNeq")
          strs <- liftEffect (callI32x0 inst "arrStrEq")
          [ eq, neq, lenN, strs ] `shouldEqual` [ 1, 0, 0, 1 ]

        it "Array ordering is lexicographic (incl. prefix < longer)" \inst -> do
          lt <- liftEffect (callI32x0 inst "arrLt")
          pre <- liftEffect (callI32x0 inst "arrPrefixLt")
          ge <- liftEffect (callI32x0 inst "arrGe")
          gt <- liftEffect (callI32x0 inst "arrGt")
          [ lt, pre, ge, gt ] `shouldEqual` [ 1, 1, 1, 1 ]
