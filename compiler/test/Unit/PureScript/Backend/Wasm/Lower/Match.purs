-- | Unit tests for the decision-tree pattern-match compiler
-- | (`PureScript.Backend.Wasm.Lower.Match`), focused on the behaviours specific to
-- | it: nested patterns, newtype erasure inside sub-binders, exhaustive matches,
-- | mixed constructor/literal columns, and guard rejection. Small CoreFn cases are
-- | built by hand (`Lower.Common`), lowered, and the resulting decision tree is
-- | inspected structurally.
module Test.Unit.PureScript.Backend.Wasm.Lower.Match (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.Lower (LowerError(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common
  ( alt2
  , binderAlt
  , case2
  , caseOf
  , countLitSwitches
  , ctor
  , ctorBinderT
  , def
  , exported
  , guardedAlt
  , intLitBinder
  , lam
  , litInt
  , lower
  , lv
  , newtypeBinder
  , nullBinder
  , projFieldIndices
  , switchOf
  , switchScrutinees
  , varBinder
  )

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Lower.Match (decision trees)" do
  it "compiles a nested constructor pattern to a two-level tree, projecting the field" do
    -- data Sign = Pos | Neg ; data Box = Box Sign
    -- f b = case b of Box Pos -> 1 ; Box Neg -> 2
    let
      decls =
        [ ctor "Sign" "Pos" []
        , ctor "Sign" "Neg" []
        , ctor "Box" "Box" [ "v" ]
        , def "f"
            ( lam "b"
                ( caseOf (lv "b")
                    [ binderAlt (ctorBinderT "Box" "Box" [ ctorBinderT "Sign" "Pos" [] ]) (litInt 1)
                    , binderAlt (ctorBinderT "Box" "Box" [ ctorBinderT "Sign" "Neg" [] ]) (litInt 2)
                    ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog -> case exported "f" prog of
        Nothing -> fail "expected an exported function f"
        Just fn -> do
          -- two decision nodes: one on `b` (the `Box`) and, after projecting its
          -- field, one on the inner `Sign`.
          Array.length (switchScrutinees fn.body) `shouldEqual` 2
          -- the `Box` field is projected before the inner switch
          projFieldIndices fn.body `shouldEqual` [ 0 ]

  it "erases a newtype constructor inside a sub-binder (no extra switch)" do
    -- data W = W NT ; newtype NT = NT Int
    -- f w = case w of W (NT v) -> v   -- NT is erased onto the projected field
    let
      decls =
        [ ctor "W" "W" [ "n" ]
        , def "f"
            ( lam "w"
                ( caseOf (lv "w")
                    [ binderAlt (ctorBinderT "W" "W" [ newtypeBinder "NT" [ varBinder "v" ] ]) (lv "v") ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog -> case exported "f" prog of
        Nothing -> fail "expected an exported function f"
        Just fn -> do
          -- only the `W` switch; the newtype `NT` adds none
          Array.length (switchScrutinees fn.body) `shouldEqual` 1
          projFieldIndices fn.body `shouldEqual` [ 0 ]

  it "compiles an exhaustive constructor match to a Switch with no default" do
    -- data Ty = A | B ; f x = case x of A -> 1 ; B -> 2
    let
      decls =
        [ ctor "Ty" "A" []
        , ctor "Ty" "B" []
        , def "f" (lam "x" (caseOf (lv "x") [ binderAlt (ctorBinderT "Ty" "A" []) (litInt 1), binderAlt (ctorBinderT "Ty" "B" []) (litInt 2) ]))
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog ->
        (switchOf <<< _.body <$> exported "f" prog)
          `shouldEqual` Just (Just { tags: [ 0, 1 ], hasDefault: false })

  it "compiles mixed constructor and literal columns to a Switch over a LitSwitch" do
    -- data Ty = A | B
    -- f x y = case x, y of A, 0 -> 1 ; B, _ -> 2 ; _, _ -> 3
    let
      decls =
        [ ctor "Ty" "A" []
        , ctor "Ty" "B" []
        , def "f"
            ( lam "x"
                ( lam "y"
                    ( case2 (lv "x") (lv "y")
                        [ alt2 (ctorBinderT "Ty" "A" []) (intLitBinder 0) (litInt 1)
                        , alt2 (ctorBinderT "Ty" "B" []) nullBinder (litInt 2)
                        , alt2 nullBinder nullBinder (litInt 3)
                        ]
                    )
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog -> case exported "f" prog of
        Nothing -> fail "expected an exported function f"
        Just fn -> do
          -- two decision nodes: a constructor Switch on `x` and a LitSwitch on `y`
          Array.length (switchScrutinees fn.body) `shouldEqual` 2
          countLitSwitches fn.body `shouldEqual` 1

  it "rejects a guarded alternative (guards are not yet compiled)" do
    -- f x = case x of A | <guard> -> 1 ; _ -> 2
    let
      decls =
        [ ctor "Ty" "A" []
        , def "f"
            ( lam "x"
                ( caseOf (lv "x")
                    [ guardedAlt (ctorBinderT "Ty" "A" []) (litInt 1) (litInt 1)
                    , binderAlt nullBinder (litInt 2)
                    ]
                )
            )
        ]
    case lower decls of
      Left GuardedCaseUnsupported -> pure unit
      Left err -> fail ("expected GuardedCaseUnsupported, got " <> show err)
      Right _ -> fail "expected the guarded match to be rejected"
