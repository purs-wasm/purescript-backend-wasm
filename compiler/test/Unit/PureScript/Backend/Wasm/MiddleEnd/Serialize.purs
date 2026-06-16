-- | Round-trip tests for the MIR cache codec. The type system guarantees nothing
-- | about `decode <<< encode`: a mismatched tag, a forgotten field, or a wrong
-- | argument order in `getExpr` would all type-check yet silently corrupt a reloaded
-- | module — exactly the law-shaped invariant CLAUDE.md says tests are for. The
-- | inputs deliberately exercise every node, both `Maybe`/`Either` branches, every
-- | `Meta` and `Binder` shape, and the leaf edge cases (negative ints, unicode,
-- | empty arrays, deep nesting) that off-by-one byte handling tends to break.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (decode, encode)
import PureScript.CoreFn (Ann, Binder(..), ConstructorType(..), Literal(..), Meta(..), Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- | A round-trip must reconstruct the exact same module.
roundTrips :: M.Module -> Either String M.Module
roundTrips = encode >>> decode

ann0 :: Ann
ann0 = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

-- | A binder annotation with a non-zero span and meta, so span/meta fidelity is tested.
ann1 :: Ann
ann1 = { span: { start: { line: 1, column: 2 }, end: { line: 3, column: 4 } }, meta: Just IsNewtype }

local :: String -> M.Expr
local x = M.Var (Qualified Nothing x)

-- | A module whose declarations together touch every `Expr`, `Bind`, `Literal`,
-- | `Binder`, `Meta` and result-branch constructor.
full :: M.Module
full =
  { name: [ "Test", "Coverage" ]
  , decls:
      [ M.NonRec Nothing "litInt" (M.Lit (LitInt (-42)))
      , M.NonRec (Just IsNewtype) "qual" (M.Var (Qualified (Just [ "Data", "Maybe" ]) "Just"))
      , M.NonRec (Just (IsConstructor SumType [ "a", "b" ])) "ctor" (M.Constructor "T" "C" [ "a", "b" ])
      , M.NonRec (Just IsTypeClassConstructor) "absApp"
          (M.Abs [ "x", "y" ] (M.App (local "x") [ local "y", M.Lit (LitBoolean true) ]))
      , M.NonRec (Just IsForeign) "acc" (M.Accessor "field" (local "rec"))
      , M.NonRec (Just IsWhere) "monoUpdate"
          (M.Update (local "rec") (Just [ "keep1", "keep2" ]) [ Tuple "a" (M.Lit (LitInt 1)), Tuple "b" (M.Lit (LitNumber 2.5)) ])
      , M.NonRec (Just IsSyntheticApp) "polyUpdate"
          (M.Update (local "rec") Nothing [ Tuple "x" (M.Lit (LitString "hi")) ])
      , M.NonRec Nothing "perform"
          (M.Perform (M.App (M.Var (Qualified (Just [ "Effect" ]) "pure")) [ M.Lit (LitChar 'q') ]))
      , M.NonRec Nothing "letBind"
          (M.Let [ M.NonRec Nothing "a" (M.Lit (LitInt 1)) ] (local "a"))
      , M.NonRec Nothing "arr" (M.Lit (LitArray [ M.Lit (LitInt 1), M.Lit (LitInt 2) ]))
      , M.NonRec Nothing "obj"
          (M.Lit (LitObject [ Tuple "k1" (M.Lit (LitString "ünïcödé 🎉")), Tuple "k2" (M.Lit (LitArray [])) ]))
      , M.NonRec Nothing "caseExpr"
          ( M.Case [ local "s1", local "s2" ]
              [ { binders: [ VarBinder ann1 "p", NullBinder ann0 ], result: Right (M.Lit (LitInt 0)) }
              , { binders:
                    [ ConstructorBinder ann1 (Qualified (Just [ "M" ]) "T") (Qualified (Just [ "M" ]) "C")
                        [ NamedBinder ann0 "n" (LiteralBinder ann0 (LitBoolean false)) ]
                    ]
                , result: Left [ { guard: M.Lit (LitBoolean true), expression: M.Lit (LitInt 9) } ]
                }
              ]
          )
      , M.Rec
          [ { meta: Nothing, ident: "f", expr: M.Abs [ "n" ] (M.App (local "g") [ local "n" ]) }
          , { meta: Just IsNewtype, ident: "g", expr: local "f" }
          ]
      ]
  }

-- | A nested application 1000 deep: a sanity check that realistic tree depth round-trips
-- | (the codec recurses naively, like the rest of the middle end; both degrade past a
-- | few thousand frames — for the codec this surfaces as a `decode` `Left` / a skipped
-- | cache write, never a wrong tree, so it is a safe miss rather than corruption).
deepNest :: M.Module
deepNest =
  { name: [ "Deep" ]
  , decls: [ M.NonRec Nothing "d" (Array.foldl (\acc i -> M.App acc [ M.Lit (LitInt i) ]) (local "base") (Array.range 1 1000)) ]
  }

-- | A single node carrying a very *wide* array (50k application arguments). `deepNest` exercises
-- | tree depth; this exercises `putArray` width: the old `traverse_`-based encoder built an
-- | N-deep `*>` chain that overflowed the host stack in (non-trampolined) `Effect` on a large
-- | array. 50k is well past the ~10k default-stack limit the old code died at.
wideArgs :: M.Module
wideArgs =
  { name: [ "Wide" ]
  , decls: [ M.NonRec Nothing "w" (M.App (local "f") (Array.replicate 50000 (M.Lit (LitInt 0)))) ]
  }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Serialize" do
  describe "encode/decode" do
    it "round-trips a module exercising every node, meta and branch" do
      roundTrips full `shouldEqual` Right full

    it "round-trips an empty module" do
      roundTrips { name: [ "Empty" ], decls: [] } `shouldEqual` Right { name: [ "Empty" ], decls: [] }

    it "round-trips Number edge cases" do
      let m vals = { name: [ "Nums" ], decls: map (\(Tuple n x) -> M.NonRec Nothing n (M.Lit (LitNumber x))) vals }
      let nums = m [ Tuple "neg" (-3.25), Tuple "big" 1.0e308, Tuple "small" 1.0e-308, Tuple "whole" 7.0 ]
      roundTrips nums `shouldEqual` Right nums

    it "round-trips a deeply nested tree without overflowing" do
      -- Compare as a Boolean: a derived `show` of a 1000-deep tree (on a hypothetical
      -- failure) would itself overflow and mask the real result.
      (roundTrips deepNest == Right deepNest) `shouldEqual` true

    it "round-trips a node with a very wide array without overflowing (putArray)" do
      -- Guards `putArray`'s stack safety: encoding the 50k-element argument list must not
      -- build an N-deep `*>` chain. Compared as a Boolean (a 50k-element `show` would be huge).
      (roundTrips wideArgs == Right wideArgs) `shouldEqual` true
