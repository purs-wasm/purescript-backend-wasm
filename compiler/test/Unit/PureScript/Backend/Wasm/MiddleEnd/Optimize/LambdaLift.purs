-- | Unit tests for the MIR lambda-lifting pass: a self-recursive local function is
-- | hoisted to a top-level supercombinator whose self-call is direct (the lowering
-- | then turns it into a `return_call`, verified end-to-end elsewhere).
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (spec) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift (lambdaLiftModule)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translModule)
import PureScript.CoreFn (Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common (appE, def, lam, letRec, lv, moduleNamed)

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift" do
  it "lifts a self-recursive local function to a top-level supercombinator" do
    -- f x = let go m = go m in go x   →   go$lift0 m = go$lift0 m ;  f x = go$lift0 x
    let
      f = def "f" (lam "x" (letRec "go" (lam "m" (appE (lv "go") (lv "m"))) (appE (lv "go") (lv "x"))))
      lifted = lambdaLiftModule (translModule (moduleNamed [ "T" ] [ f ]))
    -- one lifted supercombinator is prepended before the original `f`
    Array.length lifted.decls `shouldEqual` 2
    case Array.head lifted.decls of
      Just (M.NonRec _ name (M.Abs params body))
        | contains (Pattern "$lift") name -> do
            -- it captures nothing here, taking only `go`'s own parameter
            params `shouldEqual` [ "m" ]
            -- and its self-call is now a direct reference to the top-level name
            case body of
              M.App (M.Var (Qualified (Just _) callee)) _ -> callee `shouldEqual` name
              _ -> fail "expected the lifted body to be a direct self-call"
      _ -> fail "expected a lifted top-level supercombinator first"
