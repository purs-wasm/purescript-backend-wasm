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
import PureScript.Backend.Wasm.Lower.IR (LitPat(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common
  ( alt2
  , arrayBinder
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
  , litSwitchOf
  , lower
  , lv
  , namedBinder
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

  it "erases a newtype constructor wrapped in an as-pattern (x@(NT v))" do
    -- newtype NT = NT Int ; f w = case w of x@(NT v) -> v
    -- The as-pattern binds `x` to the scrutinee and the newtype `NT` is erased, so
    -- `v` is bound to the same occurrence: the whole match is irrefutable, no switch.
    -- Regression for the `--no-opt` lowering hole where `stripNewtype` skipped past a
    -- `NamedBinder` and `peelNamed` then exposed the newtype ctor unstripped, so it
    -- reached `requireCtor` and failed with `UnknownConstructor`.
    let
      decls =
        [ def "f"
            ( lam "w"
                ( caseOf (lv "w")
                    [ binderAlt (namedBinder "x" (newtypeBinder "NT" [ varBinder "v" ])) (lv "v") ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog -> case exported "f" prog of
        Nothing -> fail "expected an exported function f"
        Just fn ->
          Array.length (switchScrutinees fn.body) `shouldEqual` 0

  it "compiles an exhaustive constructor match to a Switch with no default" do
    -- data Ty = A | B ; f x = case x of A -> 1 ; B -> 2
    let
      decls =
        [ ctor "Ty" "A" []
        , ctor "Ty" "B" [ "v" ]
        , def "f" (lam "x" (caseOf (lv "x") [ binderAlt (ctorBinderT "Ty" "A" []) (litInt 1), binderAlt (ctorBinderT "Ty" "B" [ nullBinder ]) (litInt 2) ]))
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
        , ctor "Ty" "B" [ "v" ]
        , def "f"
            ( lam "x"
                ( lam "y"
                    ( case2 (lv "x") (lv "y")
                        [ alt2 (ctorBinderT "Ty" "A" []) (intLitBinder 0) (litInt 1)
                        , alt2 (ctorBinderT "Ty" "B" [ nullBinder ]) nullBinder (litInt 2)
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

  it "lowers a guarded alternative to a boolean test that falls through to the next" do
    -- f x = case x of _ | <guard> -> 1 ; _ -> 2
    -- The guarded row's pattern is irrefutable, so the whole match is a single
    -- boolean test whose else-branch is the fallthrough (the `_ -> 2` body).
    let
      decls =
        [ def "f"
            ( lam "x"
                ( caseOf (lv "x")
                    [ guardedAlt nullBinder (litInt 1) (litInt 1)
                    , binderAlt nullBinder (litInt 2)
                    ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog ->
        (litSwitchOf <<< _.body <$> exported "f" prog)
          `shouldEqual` Just (Just { pats: [ PBoolean true ], hasDefault: true })

  it "traps when a guarded alternative's guards fail and nothing follows" do
    -- f x = case x of _ | <guard> -> 1   -- partial: no fallthrough
    -- All-guards-fail must trap, so the boolean test carries no default.
    let
      decls =
        [ def "f"
            ( lam "x"
                ( caseOf (lv "x")
                    [ guardedAlt nullBinder (litInt 1) (litInt 1) ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog ->
        (litSwitchOf <<< _.body <$> exported "f" prog)
          `shouldEqual` Just (Just { pats: [ PBoolean true ], hasDefault: false })

  it "tests the constructor before the guard for a guarded constructor pattern" do
    -- f x = case x of A | <guard> -> 1 ; _ -> 2
    -- The refutable `A` is switched on first; the guard becomes a boolean test
    -- nested inside that branch.
    let
      decls =
        [ ctor "Ty" "A" [ "v" ]
        , def "f"
            ( lam "x"
                ( caseOf (lv "x")
                    [ guardedAlt (ctorBinderT "Ty" "A" [ nullBinder ]) (litInt 1) (litInt 1)
                    , binderAlt nullBinder (litInt 2)
                    ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog -> case exported "f" prog of
        Nothing -> fail "expected an exported function f"
        Just fn -> do
          -- the top node is a constructor Switch on tag 0, with a fallthrough default
          switchOf fn.body `shouldEqual` Just { tags: [ 0 ], hasDefault: true }
          -- exactly one guard test, nested inside the constructor branch
          countLitSwitches fn.body `shouldEqual` 1

  it "switches an array-literal pattern on its length" do
    -- f xs = case xs of [] -> 1 ; _ -> 2
    let
      decls =
        [ def "f"
            ( lam "xs"
                ( caseOf (lv "xs")
                    [ binderAlt (arrayBinder []) (litInt 1)
                    , binderAlt nullBinder (litInt 2)
                    ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog ->
        -- the `ArrayLength` is bound by a `Let`; `litSwitchOf` looks past it to the
        -- length `LitSwitch`, which tests for length 0 with a catch-all default.
        (litSwitchOf <<< _.body <$> exported "f" prog)
          `shouldEqual` Just (Just { pats: [ PInt 0 ], hasDefault: true })

  it "binds array elements by index for a fixed-length pattern" do
    -- f xs = case xs of [] -> 0 ; [a, b] -> a ; _ -> 9
    -- Referencing `a` in the body only resolves if the element sub-binders are
    -- projected and bound, so a successful lowering is itself the assertion.
    let
      decls =
        [ def "f"
            ( lam "xs"
                ( caseOf (lv "xs")
                    [ binderAlt (arrayBinder []) (litInt 0)
                    , binderAlt (arrayBinder [ varBinder "a", varBinder "b" ]) (lv "a")
                    , binderAlt nullBinder (litInt 9)
                    ]
                )
            )
        ]
    case lower decls of
      Left err -> fail (show err)
      Right prog ->
        -- one length switch with branches for lengths 0 and 2, plus a catch-all
        (litSwitchOf <<< _.body <$> exported "f" prog)
          `shouldEqual` Just (Just { pats: [ PInt 0, PInt 2 ], hasDefault: true })
