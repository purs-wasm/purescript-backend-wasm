-- | Unit tests for the free-variable analysis. Its type guarantees nothing
-- | about correctness — capturing a bound variable, missing a free one, or
-- | mis-ordering would all type-check — so the scoping invariant is exactly the
-- | kind of property that warrants tests (see the testing philosophy in
-- | CLAUDE.md).
module Test.Unit.PureScript.Backend.Wasm.Lower.FreeVars (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.Lower.FreeVars (freeVars)
import PureScript.CoreFn as CF
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

ann :: CF.Ann
ann = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

-- | A local variable reference.
lv :: String -> CF.Expr
lv x = CF.Var ann (CF.Qualified Nothing x)

-- | A module-qualified reference (top-level / foreign name).
qv :: String -> CF.Expr
qv x = CF.Var ann (CF.Qualified (Just [ "M" ]) x)

appE :: CF.Expr -> CF.Expr -> CF.Expr
appE f a = CF.App ann f a

lam :: String -> CF.Expr -> CF.Expr
lam p b = CF.Abs ann p b

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Lower.FreeVars" do
  it "reports a free local variable" do
    freeVars [] (lv "x") `shouldEqual` [ "x" ]

  it "excludes variables already in scope" do
    freeVars [ "x" ] (lv "x") `shouldEqual` []

  it "never captures qualified (top-level / foreign) names" do
    freeVars [] (qv "foo") `shouldEqual` []

  it "excludes a lambda's own parameter but keeps its free variables" do
    freeVars [] (lam "y" (appE (lv "x") (lv "y"))) `shouldEqual` [ "x" ]

  it "collects free variables from both sides of an application" do
    freeVars [] (appE (lv "a") (lv "b")) `shouldEqual` [ "a", "b" ]

  it "deduplicates repeated occurrences" do
    freeVars [] (appE (lv "a") (lv "a")) `shouldEqual` [ "a" ]

  it "handles nested lambdas, excluding every bound parameter" do
    freeVars [] (lam "y" (lam "z" (appE (appE (lv "x") (lv "y")) (lv "z")))) `shouldEqual` [ "x" ]
