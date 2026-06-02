-- | Unit tests for the MIR simplifier — the reduction engine for dictionary
-- | elimination. The headline case is a method accessor applied to an instance
-- | dictionary collapsing to the underlying implementation.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify (spec) where

import Prelude

import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify (Ctx, simplifyExpr)
import PureScript.CoreFn (Ann, Binder(..), Literal(..), Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- helpers ---------------------------------------------------------------------

tv :: String -> M.Expr
tv n = M.Var (Qualified (Just [ "T" ]) n)

loc :: String -> M.Expr
loc n = M.Var (Qualified Nothing n)

bann :: Ann
bann = { span: { start: origin, end: origin }, meta: Nothing }
  where
  origin = { line: 0, column: 0 }

-- The `Eq$Dict` newtype ctor: transparent (its case binds the payload) and, on the
-- value side, the identity function (so an instance unwraps to its record).
ctx :: Ctx
ctx =
  { newtypeCtors: Set.singleton "T.Eq$Dict"
  , dataCtors: Set.fromFoldable [ "T.A", "T.B" ]
  , inline: Map.singleton "T.Eq$Dict" (M.Abs [ "x" ] (loc "x"))
  , instanceFields: Map.singleton "T.heytingBool" [ Tuple "disj" (tv "boolDisj") ]
  }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify" do
  it "projects a field from a known record" do
    -- { eq: impl }.eq  →  impl
    simplifyExpr ctx (M.Accessor "eq" (M.Lit (LitObject [ Tuple "eq" (tv "impl") ])))
      `shouldEqual` tv "impl"

  it "projects a method off a known plain-record instance by name" do
    -- heytingBool.disj  →  boolDisj   (a bare-record instance, projected by name)
    simplifyExpr ctx (M.Accessor "disj" (tv "heytingBool")) `shouldEqual` tv "boolDisj"

  it "beta-reduces an applied lambda" do
    -- (\x -> x)(impl)  →  impl
    simplifyExpr ctx (M.App (M.Abs [ "x" ] (loc "x")) [ tv "impl" ])
      `shouldEqual` tv "impl"

  it "short-circuits the boolean OR operator into a case" do
    -- boolDisj(a, b)  →  case a of true -> true ; _ -> b   (b evaluated only if needed)
    let boolDisj = M.Var (Qualified (Just [ "Data", "HeytingAlgebra" ]) "boolDisj")
    simplifyExpr ctx (M.App boolDisj [ tv "a", tv "b" ])
      `shouldEqual`
        M.Case [ tv "a" ]
          [ { binders: [ LiteralBinder bann (LitBoolean true) ], result: Right (M.Lit (LitBoolean true)) }
          , { binders: [ NullBinder bann ], result: Right (tv "b") }
          ]

  it "unwraps a transparent dict constructor (identity) on the value side" do
    -- Eq$Dict(impl)  →  impl   (via inlining Eq$Dict = \x -> x, then beta)
    simplifyExpr ctx (M.App (tv "Eq$Dict") [ tv "impl" ])
      `shouldEqual` tv "impl"

  it "eliminates a method accessor applied to an instance dictionary" do
    -- (\d -> case d of Eq$Dict(v) -> v.eq) (Eq$Dict({ eq: impl }))  →  impl
    let
      accessor = M.Abs [ "d" ]
        ( M.Case [ loc "d" ]
            [ { binders: [ ConstructorBinder bann (Qualified (Just [ "T" ]) "Eq") (Qualified (Just [ "T" ]) "Eq$Dict") [ VarBinder bann "v" ] ]
              , result: Right (M.Accessor "eq" (loc "v"))
              }
            ]
        )
      instanceDict = M.App (tv "Eq$Dict") [ M.Lit (LitObject [ Tuple "eq" (tv "impl") ]) ]
    simplifyExpr ctx (M.App accessor [ instanceDict ]) `shouldEqual` tv "impl"

  it "selects the matching alternative for a known data constructor" do
    -- case B(impl) of A -> 0 ; B(v) -> v   →   impl
    let
      ty = Qualified (Just [ "T" ]) "Sum"
      scrut = M.App (tv "B") [ tv "impl" ]
      alts =
        [ { binders: [ ConstructorBinder bann ty (Qualified (Just [ "T" ]) "A") [] ], result: Right (M.Lit (LitInt 0)) }
        , { binders: [ ConstructorBinder bann ty (Qualified (Just [ "T" ]) "B") [ VarBinder bann "v" ] ], result: Right (loc "v") }
        ]
    simplifyExpr ctx (M.Case [ scrut ] alts) `shouldEqual` tv "impl"
