-- | Unit tests for the CoreFn → IR lowering, focused on closure conversion
-- | (Slice 2): lambda lifting, free-variable capture, `EnvField` reads, and the
-- | known-call vs unknown-apply distinction. Small CoreFn modules are built by
-- | hand and lowered, and the resulting IR is inspected structurally (rather
-- | than by exact slot numbers, which would be brittle).
module Test.Unit.PureScript.Backend.Wasm.Lower (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (Atom(..), FuncName(..), LitPat(..), RecBind(..), Rep(..), VarRef(..))
import PureScript.CoreFn as CF
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common (allRhs, ann, appE, blockAtoms, boolAlt, caseOf, closureCaptures, ctor, ctorAlt, def, dictCtorDecl, exportOf, exported, intAlt, isApply, isCallForeign, isPrim, lam, letRec2, liftedFuncs, litInt, litObj, litStr, litSwitchOf, lower, lowerForeign, lowerMany, lv, mkDataTags, newtypeCase, objUpdate, projLabelIds, qv, qvIn, recAlt, recordLabelIds, strAlt, switchOf, switchScrutinees, hasSwitch, accessor, varBinder, arrayLengths, callKnownArities, callKnownNames, letRecOf, case2, ctorBinder, alt2, nullBinder, wildAlt, moduleNamed)

-- A function with a capturing lambda applied immediately:
-- `f a b = (\y -> intAdd a y) b`. The lambda captures `a`.
fDecl :: CF.Bind
fDecl = def "f" (lam "a" (lam "b" (appE (lam "y" (appE (appE (qv "intAdd") (lv "a")) (lv "y"))) (lv "b"))))

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Lower (lowering)" do
  describe "closure conversion" do
    it "lifts a capturing lambda to a separate code function" do
      case lower [ fDecl ] of
        Left err -> fail (show err)
        Right prog -> do
          -- the original function plus one lifted code function
          Array.length prog.funcs `shouldEqual` 2
          (_.params <$> exported "f" prog) `shouldEqual` Just [ Boxed, Boxed ]
          -- the lifted code function takes (ref $Clo, eqref)
          (_.params <$> Array.head (liftedFuncs prog)) `shouldEqual` Just [ CloRef, Boxed ]

    it "captures exactly the lambda's free variable (not its parameter)" do
      case lower [ fDecl ] of
        Left err -> fail (show err)
        Right prog -> case exported "f" prog of
          Nothing -> fail "expected an exported function f"
          Just fn -> (Array.length <$> closureCaptures fn.body) `shouldEqual` [ 1 ]

    it "reads the captured variable as an EnvField in the lifted code" do
      case lower [ fDecl ] of
        Left err -> fail (show err)
        Right prog -> case Array.head (liftedFuncs prog) of
          Nothing -> fail "expected a lifted code function"
          Just code -> Array.elem (AVar (EnvField 0)) (blockAtoms code.body) `shouldEqual` true

  describe "application" do
    it "lowers application of a local value to a closure apply (call_ref)" do
      -- g f x = f x  -- f is an unknown function value
      let g = def "g" (lam "f" (lam "x" (appE (lv "f") (lv "x"))))
      case lower [ g ] of
        Left err -> fail (show err)
        Right prog -> do
          Array.length prog.funcs `shouldEqual` 1 -- no lambda, so no lift
          case exported "g" prog of
            Nothing -> fail "expected an exported function g"
            Just fn -> Array.any isApply (allRhs fn.body) `shouldEqual` true

    it "chains a multi-argument application into single-argument applies" do
      -- g f x y = f x y  -- an unknown 2-argument application
      let g = def "g" (lam "f" (lam "x" (lam "y" (appE (appE (lv "f") (lv "x")) (lv "y")))))
      case lower [ g ] of
        Left err -> fail (show err)
        Right prog -> case exported "g" prog of
          Nothing -> fail "expected an exported function g"
          Just fn -> Array.length (Array.filter isApply (allRhs fn.body)) `shouldEqual` 2

    it "keeps a saturated intrinsic as a primitive, not an apply" do
      -- h x = intAdd x x
      let h = def "h" (lam "x" (appE (appE (qv "intAdd") (lv "x")) (lv "x")))
      case lower [ h ] of
        Left err -> fail (show err)
        Right prog -> case exported "h" prog of
          Nothing -> fail "expected an exported function h"
          Just fn -> do
            Array.any isPrim (allRhs fn.body) `shouldEqual` true
            Array.any isApply (allRhs fn.body) `shouldEqual` false

    it "lowers a partial application of a known function to a closure (PAP)" do
      -- two a b = intAdd a b ; p x = two x   -- `two x` is under-applied
      let two = def "two" (lam "a" (lam "b" (appE (appE (qv "intAdd") (lv "a")) (lv "b"))))
      let p = def "p" (lam "x" (appE (qv "two") (lv "x")))
      case lower [ two, p ] of
        Left err -> fail (show err)
        Right prog -> case exported "p" prog of
          Nothing -> fail "expected an exported function p"
          Just fn -> do
            -- the missing argument is supplied by eta-expanding `two` into a
            -- closure (lifted code functions) which is then applied
            (Array.length (closureCaptures fn.body) > 0) `shouldEqual` true
            Array.any isApply (allRhs fn.body) `shouldEqual` true

  describe "recursion" do
    -- Self-recursive local functions are lifted to top-level supercombinators by
    -- the middle-end's lambda-lifting pass, not by lowering; that lift (and the
    -- resulting direct self-call) is covered in `Test.…MiddleEnd.Optimize.LambdaLift`.
    it "compiles a mutually-recursive let to a knot-tied LetRec group" do
      -- p x = let ev m = od m; od m = ev m in ev x
      let
        p = def "p"
          ( lam "x"
              ( letRec2
                  "ev"
                  (lam "m" (appE (lv "od") (lv "m")))
                  "od"
                  (lam "m" (appE (lv "ev") (lv "m")))
                  (appE (lv "ev") (lv "x"))
              )
          )
      case lower [ p ] of
        Left err -> fail (show err)
        Right prog -> case exported "p" prog of
          Nothing -> fail "expected an exported function p"
          Just fn -> case letRecOf fn.body of
            Nothing -> fail "expected a LetRec group"
            -- two members, each capturing exactly its sibling
            Just rbs -> map (\(RecBind _ _ env) -> Array.length env) rbs `shouldEqual` [ 1, 1 ]

  describe "data types" do
    it "assigns constructor tags by declaration order and erases the constructors" do
      -- data D = A | B Int ; mkA = A ; mkB x = B x
      let
        decls =
          [ ctor "D" "A" []
          , ctor "D" "B" [ "value0" ]
          , def "mkA" (qv "A")
          , def "mkB" (lam "x" (appE (qv "B") (lv "x")))
          ]
      case lower decls of
        Left err -> fail (show err)
        Right prog -> do
          -- the constructors are erased (not emitted as functions); only mkA/mkB remain
          Array.length prog.funcs `shouldEqual` 2
          (mkDataTags <<< _.body <$> exported "mkA" prog) `shouldEqual` Just [ 0 ]
          (mkDataTags <<< _.body <$> exported "mkB" prog) `shouldEqual` Just [ 1 ]

    it "compiles a constructor match with a catch-all to a Switch with a default" do
      -- data Ty = A | B ; f x = case x of A -> 1; _ -> 0
      let
        decls =
          [ ctor "Ty" "A" []
          , ctor "Ty" "B" [ "v" ]
          , def "f" (lam "x" (caseOf (lv "x") [ ctorAlt "A" [] (litInt 1), wildAlt (litInt 0) ]))
          ]
      case lower decls of
        Left err -> fail (show err)
        Right prog ->
          (switchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { tags: [ 0 ], hasDefault: true })

    it "compiles overlapping multi-scrutinee patterns to a decision tree that tests each scrutinee at most once" do
      -- A deliberately redundant match: the constructor `A` heads three of the five
      -- alternatives. A naive backtracking compiler would re-test `x == A` once per
      -- such row; a decision tree groups them and tests `x` a single time.
      --
      -- data Ty = A | B | C
      -- f x y = case x, y of
      --   A, A -> 1 ; A, B -> 2 ; A, C -> 3 ; B, _ -> 4 ; C, _ -> 5
      let
        decls =
          [ ctor "Ty" "A" []
          , ctor "Ty" "B" []
          , ctor "Ty" "C" []
          , def "f"
              ( lam "x"
                  ( lam "y"
                      ( case2 (lv "x") (lv "y")
                          [ alt2 (ctorBinder "A" []) (ctorBinder "A" []) (litInt 1)
                          , alt2 (ctorBinder "A" []) (ctorBinder "B" []) (litInt 2)
                          , alt2 (ctorBinder "A" []) (ctorBinder "C" []) (litInt 3)
                          , alt2 (ctorBinder "B" []) nullBinder (litInt 4)
                          , alt2 (ctorBinder "C" []) nullBinder (litInt 5)
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
            let scruts = switchScrutinees fn.body
            -- Exactly two decision nodes: one on `x` (A | B | C) and one on `y`
            -- (inside the `x = A` branch) — not one test per alternative row.
            Array.length scruts `shouldEqual` 2
            -- The outer scrutinee `x` is examined exactly once, despite `A` heading
            -- three alternatives.
            case Array.head scruts of
              Nothing -> fail "expected at least one Switch"
              Just x -> Array.length (Array.filter (_ == x) scruts) `shouldEqual` 1

  describe "records and dictionaries" do
    it "lowers a record literal to RMkRecord with label ids sorted" do
      -- r = { b: 2, a: 1 }  -- ids assigned by sorted label: a=0, b=1
      let r = def "r" (litObj [ Tuple "b" (litInt 2), Tuple "a" (litInt 1) ])
      case lower [ r ] of
        Left err -> fail (show err)
        Right prog ->
          (recordLabelIds <<< _.body <$> exported "r" prog) `shouldEqual` Just [ [ 0, 1 ] ]

    it "lowers a record accessor to a label-id projection" do
      -- get r = r.a  -- "a" is the only label, so it interns to 0
      let get = def "get" (lam "r" (accessor "a" (lv "r")))
      case lower [ get ] of
        Left err -> fail (show err)
        Right prog ->
          (projLabelIds <<< _.body <$> exported "get" prog) `shouldEqual` Just [ 0 ]

    it "lowers a record update to a rebuilt record (updated + copied fields)" do
      -- f r = r { a = 1 }  -- record is { a, b }, so b is copied; ids a=0, b=1
      let f = def "f" (lam "r" (objUpdate (lv "r") [ "b" ] [ Tuple "a" (litInt 1) ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog -> do
          (recordLabelIds <<< _.body <$> exported "f" prog) `shouldEqual` Just [ [ 0, 1 ] ]
          -- the untouched field b is projected out of the original record
          (projLabelIds <<< _.body <$> exported "f" prog) `shouldEqual` Just [ 1 ]

    it "lowers a record pattern to label projections without a Switch" do
      -- f r = case r of { a: x } -> x
      let f = def "f" (lam "r" (caseOf (lv "r") [ recAlt [ Tuple "a" (varBinder "x") ] (lv "x") ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog -> case exported "f" prog of
          Nothing -> fail "expected an exported function f"
          Just fn -> do
            hasSwitch fn.body `shouldEqual` false
            projLabelIds fn.body `shouldEqual` [ 0 ]

    it "references a nullary top-level value as a (zero-argument) known call" do
      -- v = 1 ; w = v  -- the bare reference to the CAF v becomes RCallKnown v []
      let decls = [ def "v" (litInt 1), def "w" (qv "v") ]
      case lower decls of
        Left err -> fail (show err)
        Right prog ->
          (callKnownArities <<< _.body <$> exported "w" prog) `shouldEqual` Just [ 0 ]

    it "erases a dictionary constructor application to its record" do
      -- mkDict = D$Dict { a: 1 }  -- the newtype dict ctor is erased; only RMkRecord remains
      let
        decls =
          [ dictCtorDecl "D$Dict"
          , def "mkDict" (appE (qv "D$Dict") (litObj [ Tuple "a" (litInt 1) ]))
          ]
      case lower decls of
        Left err -> fail (show err)
        Right prog -> do
          -- the dict ctor is not emitted as a function; only mkDict is
          (_.export <$> prog.funcs) `shouldEqual` [ Just "mkDict" ]
          (recordLabelIds <<< _.body <$> exported "mkDict" prog) `shouldEqual` Just [ [ 0 ] ]

    it "compiles a newtype unwrap transparently (no Switch)" do
      -- unwrap d = case d of D$Dict v -> v.a  -- a method accessor's shape
      let
        decls =
          [ dictCtorDecl "D$Dict"
          , def "unwrap" (lam "d" (newtypeCase "D$Dict" (lv "d") "v" (accessor "a" (lv "v"))))
          ]
      case lower decls of
        Left err -> fail (show err)
        Right prog -> case exported "unwrap" prog of
          Nothing -> fail "expected an exported function unwrap"
          Just fn -> do
            hasSwitch fn.body `shouldEqual` false
            projLabelIds fn.body `shouldEqual` [ 0 ]

  describe "literal pattern matching" do
    it "compiles Int literal patterns with a catch-all to a LitSwitch" do
      -- f n = case n of 0 -> 100; 7 -> 700; _ -> 999
      let f = def "f" (lam "n" (caseOf (lv "n") [ intAlt 0 (litInt 100), intAlt 7 (litInt 700), wildAlt (litInt 999) ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog ->
          (litSwitchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { pats: [ PInt 0, PInt 7 ], hasDefault: true })

    it "compiles a Boolean match to a LitSwitch on i31 Booleans" do
      -- f b = case b of true -> 1; false -> 0
      let f = def "f" (lam "b" (caseOf (lv "b") [ boolAlt true (litInt 1), boolAlt false (litInt 0) ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog ->
          (litSwitchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { pats: [ PBoolean true, PBoolean false ], hasDefault: false })

    it "drops alternatives after a catch-all (they are unreachable)" do
      -- f n = case n of 0 -> 1; _ -> 2; 5 -> 3   (the 5 arm is dead)
      let f = def "f" (lam "n" (caseOf (lv "n") [ intAlt 0 (litInt 1), wildAlt (litInt 2), intAlt 5 (litInt 3) ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog ->
          (litSwitchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { pats: [ PInt 0 ], hasDefault: true })

    it "lowers a case in argument position (commuting conversion)" do
      -- f x = g (case x of 0 -> 100 ; _ -> x)
      -- The case is an *argument* (not in tail position); it lowers to a `LitSwitch`
      -- whose branches each continue with the surrounding call to `g`.
      let
        decls =
          [ def "g" (lam "y" (lv "y"))
          , def "f" (lam "x" (appE (qv "g") (caseOf (lv "x") [ intAlt 0 (litInt 100), wildAlt (lv "x") ])))
          ]
      case lower decls of
        Left err -> fail (show err)
        Right prog ->
          (litSwitchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { pats: [ PInt 0 ], hasDefault: true })

    it "compiles String literal patterns to a LitSwitch on PString" do
      -- f s = case s of "hi" -> 1; "ho" -> 2; _ -> 0
      let f = def "f" (lam "s" (caseOf (lv "s") [ strAlt "hi" (litInt 1), strAlt "ho" (litInt 2), wildAlt (litInt 0) ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog ->
          (litSwitchOf <<< _.body <$> exported "f" prog)
            `shouldEqual` Just (Just { pats: [ PString "hi", PString "ho" ], hasDefault: true })

    it "lowers a foreign string concat to a primitive" do
      -- f = concatS "a" "b"
      let f = def "f" (appE (appE (qv "concatS") (litStr "a")) (litStr "b"))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog -> case exported "f" prog of
          Nothing -> fail "expected an exported function f"
          Just fn -> Array.any isPrim (allRhs fn.body) `shouldEqual` true

    it "resolves a non-intrinsic foreign import to a host-import call" do
      -- f = addOne 1   where Ext.addOne :: Int -> Int is a user foreign (ADR 0014)
      let
        f = def "f" (appE (qvIn "Ext" "addOne") (litInt 1))
        sigs = Object.singleton "Ext.addOne" { moduleName: "Ext", base: "addOne", params: [ I32 ], result: I32 }
      case lowerForeign sigs [ f ] of
        Left err -> fail (show err)
        Right prog -> case exported "f" prog of
          Nothing -> fail "expected an exported function f"
          Just fn -> Array.any isCallForeign (allRhs fn.body) `shouldEqual` true

    it "resolves a nullary foreign import (a constant) to a host-import call" do
      -- f = maxInt   where Ext.maxInt :: Int is a nullary foreign — the params-empty
      -- branch materializes it directly rather than eta-expanding (ADR 0014)
      let
        f = def "f" (qvIn "Ext" "maxInt")
        sigs = Object.singleton "Ext.maxInt" { moduleName: "Ext", base: "maxInt", params: [], result: I32 }
      case lowerForeign sigs [ f ] of
        Left err -> fail (show err)
        Right prog -> case exported "f" prog of
          Nothing -> fail "expected an exported function f"
          Just fn -> Array.any isCallForeign (allRhs fn.body) `shouldEqual` true

    it "lowers an array literal to RMkArray over its elements" do
      -- f = [ 10, 20, 30 ]
      let f = def "f" (CF.Literal ann (CF.LitArray [ litInt 10, litInt 20, litInt 30 ]))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog ->
          (arrayLengths <<< _.body <$> exported "f" prog) `shouldEqual` Just [ 3 ]

  describe "linking" do
    it "resolves a cross-module call by qualified name and exports only roots" do
      -- module B: foo x = intAdd x x ; module A: f x = B.foo x  (root = A)
      let
        modB = moduleNamed [ "B" ] [ def "foo" (lam "x" (appE (appE (qvIn "B" "intAdd") (lv "x")) (lv "x"))) ]
        modA = moduleNamed [ "A" ] [ def "f" (lam "x" (appE (qvIn "B" "foo") (lv "x"))) ]
      case lowerMany [ [ "A" ] ] [ modA, modB ] of
        Left err -> fail (show err)
        Right prog -> do
          -- A.f is exported; B.foo is internal (DCE-eligible)
          exportOf "A.f" prog `shouldEqual` Just (Just "f")
          exportOf "B.foo" prog `shouldEqual` Just Nothing
          -- A.f calls B.foo by its qualified name
          (callKnownNames <<< _.body <$> Array.find (\fn -> fn.name == FuncName "A.f") prog.funcs)
            `shouldEqual` Just [ "B.foo" ]
