-- | Unit tests for the CoreFn → IR lowering, focused on closure conversion
-- | (Slice 2): lambda lifting, free-variable capture, `EnvField` reads, and the
-- | known-call vs unknown-apply distinction. Small CoreFn modules are built by
-- | hand and lowered, and the resulting IR is inspected structurally (rather
-- | than by exact slot numbers, which would be brittle).
module Test.Unit.PureScript.Backend.Wasm.FromCoreFn (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Foreign.Object as Object
import PureScript.Backend.Wasm.FromCoreFn (LowerError(..), lowerModule)
import PureScript.Backend.Wasm.IR (Atom(..), Block(..), Branch(..), IRFunc, Program, Rep(..), Rhs(..), VarRef(..))
import PureScript.CoreFn as CF
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- --- CoreFn builders (zero annotation) --------------------------------------

ann :: CF.Ann
ann = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

-- | A local variable reference.
lv :: String -> CF.Expr
lv x = CF.Var ann (CF.Qualified Nothing x)

-- | A module-qualified reference (foreign primitive or top-level name).
qv :: String -> CF.Expr
qv x = CF.Var ann (CF.Qualified (Just [ "T" ]) x)

appE :: CF.Expr -> CF.Expr -> CF.Expr
appE f a = CF.App ann f a

lam :: String -> CF.Expr -> CF.Expr
lam p b = CF.Abs ann p b

def :: String -> CF.Expr -> CF.Bind
def name e = CF.NonRec ann name e

-- | A data-constructor declaration (`name` of type `typeName`, with `fields`).
ctor :: String -> String -> Array String -> CF.Bind
ctor typeName name fields = CF.NonRec ann name (CF.Constructor ann typeName name fields)

lower :: Array CF.Bind -> Either LowerError Program
lower decls = lowerModule
  { name: [ "T" ]
  , path: "T.purs"
  , builtWith: "0.15.16"
  , imports: []
  , exports: []
  , reExports: Object.empty
  , foreignNames: []
  , decls
  }

-- --- IR inspection helpers --------------------------------------------------

-- | Every `Rhs` in a block, descending into `Switch` branches and the default.
allRhs :: Block -> Array Rhs
allRhs = case _ of
  Ret _ -> []
  Let _ _ rhs k -> Array.cons rhs (allRhs k)
  Switch _ branches dflt ->
    (branches >>= \(Branch _ b) -> allRhs b) <> maybe [] allRhs dflt

rhsAtoms :: Rhs -> Array Atom
rhsAtoms = case _ of
  RAtom a -> [ a ]
  RPrim _ as -> as
  RCallKnown _ as -> as
  RMkData _ as -> as
  RProjField a _ -> [ a ]
  RMkClosure _ as -> as
  RApply a as -> Array.cons a as

-- | Every `Atom` appearing in a block.
blockAtoms :: Block -> Array Atom
blockAtoms = case _ of
  Ret a -> [ a ]
  Let _ _ rhs k -> rhsAtoms rhs <> blockAtoms k
  Switch s branches dflt ->
    Array.cons s ((branches >>= \(Branch _ b) -> blockAtoms b) <> maybe [] blockAtoms dflt)

-- | The capture lists of every `RMkClosure` in a block.
closureCaptures :: Block -> Array (Array Atom)
closureCaptures b = Array.mapMaybe captureOf (allRhs b)
  where
  captureOf = case _ of
    RMkClosure _ caps -> Just caps
    _ -> Nothing

-- | The constructor tags of every `RMkData` in a block.
mkDataTags :: Block -> Array Int
mkDataTags b = Array.mapMaybe tagOf (allRhs b)
  where
  tagOf = case _ of
    RMkData tag _ -> Just tag
    _ -> Nothing

isApply :: Rhs -> Boolean
isApply = case _ of
  RApply _ _ -> true
  _ -> false

isPrim :: Rhs -> Boolean
isPrim = case _ of
  RPrim _ _ -> true
  _ -> false

exported :: String -> Program -> Maybe IRFunc
exported name prog = Array.find (\fn -> fn.export == Just name) prog.funcs

liftedFuncs :: Program -> Array IRFunc
liftedFuncs prog = Array.filter (\fn -> fn.export == Nothing) prog.funcs

-- A function with a capturing lambda applied immediately:
-- `f a b = (\y -> addI a y) b`. The lambda captures `a`.
fDecl :: CF.Bind
fDecl = def "f" (lam "a" (lam "b" (appE (lam "y" (appE (appE (qv "addI") (lv "a")) (lv "y"))) (lv "b"))))

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.FromCoreFn (lowering)" do
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

    it "keeps a saturated intrinsic as a primitive, not an apply" do
      -- h x = addI x x
      let h = def "h" (lam "x" (appE (appE (qv "addI") (lv "x")) (lv "x")))
      case lower [ h ] of
        Left err -> fail (show err)
        Right prog -> case exported "h" prog of
          Nothing -> fail "expected an exported function h"
          Just fn -> do
            Array.any isPrim (allRhs fn.body) `shouldEqual` true
            Array.any isApply (allRhs fn.body) `shouldEqual` false

    it "rejects partial application of a known multi-argument function" do
      -- two a b = addI a b ; p x = two x   -- `two x` is under-applied
      let two = def "two" (lam "a" (lam "b" (appE (appE (qv "addI") (lv "a")) (lv "b"))))
      let p = def "p" (lam "x" (appE (qv "two") (lv "x")))
      case lower [ two, p ] of
        Left err -> err `shouldEqual` NotSaturated "two" 2 1
        Right _ -> fail "expected partial application to be rejected"

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
