-- | CLI-driven e2e (ADR 0031 phase 5) of `Eq`/`Ord` across types: `Boolean`/`Number`/`String` and
-- | derived instances on ADTs (single/multi-constructor, nullary and with fields), plus `Array`
-- | equality and lexicographic ordering — exercising the ulib `Data.Eq`/`Data.Ord` shadows (incl.
-- | their `String`/`Array` foreigns) through the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.PreludeEqOrd`.)
module Test.E2E.Cli.PreludeEqOrd (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Eq/Ord across types (e2e/cli): Bool/Number/String/ADT/Array -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.EqOrd"))
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

        it "derived Eq on a single-constructor ADT compares its fields" \inst -> do
          peq <- liftEffect (callI32x0 inst "pairEq")
          pneq <- liftEffect (callI32x0 inst "pairNeq")
          [ peq, pneq ] `shouldEqual` [ 1, 0 ]

        it "derived Eq/Ord on a multi-constructor nullary ADT" \inst -> do
          eq <- liftEffect (callI32x0 inst "colorEq")
          neq <- liftEffect (callI32x0 inst "colorNeq")
          lt <- liftEffect (callI32x0 inst "colorLt")
          gt <- liftEffect (callI32x0 inst "colorGt")
          [ eq, neq, lt, gt ] `shouldEqual` [ 1, 0, 1, 1 ]

        it "derived Eq on a multi-constructor ADT with fields" \inst -> do
          eqc <- liftEffect (callI32x0 inst "shapeEqC")
          neqArg <- liftEffect (callI32x0 inst "shapeNeqArg")
          neqCtor <- liftEffect (callI32x0 inst "shapeNeqCtor")
          eqr <- liftEffect (callI32x0 inst "shapeEqR")
          [ eqc, neqArg, neqCtor, eqr ] `shouldEqual` [ 1, 0, 0, 1 ]

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
