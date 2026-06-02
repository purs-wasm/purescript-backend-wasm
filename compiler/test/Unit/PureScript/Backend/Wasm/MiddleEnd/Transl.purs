-- | Unit tests for the CoreFn → middle-IR translation (`MiddleEnd.Transl`). The
-- | structural change worth checking is **uncurrying**; the rest is a faithful
-- | mapping, exercised over the real fixture corpus to confirm it is total.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Transl (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Class (liftEffect)
import PureScript.Backend.Wasm.Compiler (parseModule)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Transl (translBind, translExpr, translModule)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common (appE, def, lam, litInt, lv, qv)

foreign import readFixture :: String -> Effect String

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Transl (CoreFn -> MIR)" do
  it "uncurries a curried lambda and application" do
    -- \a b -> f a b   →   Abs [a, b] (App (Var f) [a, b])
    case translExpr (lam "a" (lam "b" (appE (appE (qv "f") (lv "a")) (lv "b")))) of
      M.Abs params body -> do
        params `shouldEqual` [ "a", "b" ]
        case body of
          M.App _ args -> Array.length args `shouldEqual` 2
          _ -> fail "expected an App body"
      _ -> fail "expected an uncurried Abs"

  it "leaves a nullary value as a value, not an Abs" do
    -- x = 5   →   NonRec x (Lit …)   (CAFs are not lambdas)
    case translBind (def "x" (litInt 5)) of
      M.NonRec _ "x" (M.Lit _) -> pure unit
      _ -> fail "expected NonRec x = Lit"

  it "translates the fixture corpus without partiality (decl count preserved)" do
    for_ corpus \name -> do
      let path = "compiler/test/fixtures/" <> name <> ".corefn.json"
      source <- liftEffect (readFixture path)
      case parseModule source of
        Left err -> fail (name <> ": " <> err)
        Right m -> Array.length (translModule m).decls `shouldEqual` Array.length m.decls

-- A spread of fixtures: every CoreFn node kind (Sample), ADTs (Slice1), arrays
-- (Slice4c), records (Records), dictionaries (Cmp), generics (Gen, GenSC), and an
-- integration program (Expr).
corpus :: Array String
corpus = [ "Sample", "Slice1", "Slice4c", "Records", "Cmp", "Gen", "GenSC", "Expr" ]
