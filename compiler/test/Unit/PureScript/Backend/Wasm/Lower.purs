-- | Unit tests for the CoreFn → IR lowering, focused on closure conversion
-- | (Slice 2): lambda lifting, free-variable capture, `EnvField` reads, and the
-- | known-call vs unknown-apply distinction. Small CoreFn modules are built by
-- | hand and lowered, and the resulting IR is inspected structurally (rather
-- | than by exact slot numbers, which would be brittle).
module Test.Unit.PureScript.Backend.Wasm.Lower (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower (LowerError, lowerModule)
import PureScript.Backend.Wasm.IR (Atom(..), AnfExpr(..), Branch(..), IRFunc, Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))
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

-- | `let { name = recExpr } in body`, as a single-binding recursive `let`.
letRec :: String -> CF.Expr -> CF.Expr -> CF.Expr
letRec name recExpr body = CF.Let ann [ CF.Rec [ { ann, ident: name, expr: recExpr } ] ] body

-- | `let { n1 = e1; n2 = e2 } in body`, as a two-binding recursive `let`.
letRec2 :: String -> CF.Expr -> String -> CF.Expr -> CF.Expr -> CF.Expr
letRec2 n1 e1 n2 e2 body =
  CF.Let ann [ CF.Rec [ { ann, ident: n1, expr: e1 }, { ann, ident: n2, expr: e2 } ] ] body

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
allRhs :: AnfExpr -> Array Rhs
allRhs = case _ of
  Return _ -> []
  Let _ _ rhs k -> Array.cons rhs (allRhs k)
  Switch _ branches dflt ->
    (branches >>= \(Branch _ b) -> allRhs b) <> maybe [] allRhs dflt
  LetRec _ k -> allRhs k

rhsAtoms :: Rhs -> Array Atom
rhsAtoms = case _ of
  RAtom a -> [ a ]
  RPrim _ as -> as
  RCallKnown _ as -> as
  RMkData _ as -> as
  RProjField a _ -> [ a ]
  RMkClosure _ as -> as
  RApply f a -> [ f, a ]

-- | Every `Atom` appearing in a block.
blockAtoms :: AnfExpr -> Array Atom
blockAtoms = case _ of
  Return a -> [ a ]
  Let _ _ rhs k -> rhsAtoms rhs <> blockAtoms k
  Switch s branches dflt ->
    Array.cons s ((branches >>= \(Branch _ b) -> blockAtoms b) <> maybe [] blockAtoms dflt)
  LetRec recBinds k -> (recBinds >>= \(RecBind _ _ env) -> env) <> blockAtoms k

-- | The capture lists of every `RMkClosure` in a block.
closureCaptures :: AnfExpr -> Array (Array Atom)
closureCaptures b = Array.mapMaybe captureOf (allRhs b)
  where
  captureOf = case _ of
    RMkClosure _ caps -> Just caps
    _ -> Nothing

-- | The constructor tags of every `RMkData` in a block.
mkDataTags :: AnfExpr -> Array Int
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

-- | An application of the closure's own parameter (local 0) — i.e. a recursive
-- | self-call routed through the closure rather than through a captured copy.
selfApply :: Rhs -> Boolean
selfApply = case _ of
  RApply (AVar (Local (Slot 0))) _ -> true
  _ -> false

-- | The members of the first `LetRec` group reachable along the `Let` spine.
letRecOf :: AnfExpr -> Maybe (Array RecBind)
letRecOf = case _ of
  LetRec rbs _ -> Just rbs
  Let _ _ _ k -> letRecOf k
  _ -> Nothing

exported :: String -> Program -> Maybe IRFunc
exported name prog = Array.find (\fn -> fn.export == Just name) prog.funcs

liftedFuncs :: Program -> Array IRFunc
liftedFuncs prog = Array.filter (\fn -> fn.export == Nothing) prog.funcs

-- A function with a capturing lambda applied immediately:
-- `f a b = (\y -> addI a y) b`. The lambda captures `a`.
fDecl :: CF.Bind
fDecl = def "f" (lam "a" (lam "b" (appE (lam "y" (appE (appE (qv "addI") (lv "a")) (lv "y"))) (lv "b"))))

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
      -- h x = addI x x
      let h = def "h" (lam "x" (appE (appE (qv "addI") (lv "x")) (lv "x")))
      case lower [ h ] of
        Left err -> fail (show err)
        Right prog -> case exported "h" prog of
          Nothing -> fail "expected an exported function h"
          Just fn -> do
            Array.any isPrim (allRhs fn.body) `shouldEqual` true
            Array.any isApply (allRhs fn.body) `shouldEqual` false

    it "lowers a partial application of a known function to a closure (PAP)" do
      -- two a b = addI a b ; p x = two x   -- `two x` is under-applied
      let two = def "two" (lam "a" (lam "b" (appE (appE (qv "addI") (lv "a")) (lv "b"))))
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
    it "compiles a self-recursive let by recurring through the closure parameter" do
      -- f x = let go m = go m in go x   (go refers to itself)
      let f = def "f" (lam "x" (letRec "go" (lam "m" (appE (lv "go") (lv "m"))) (appE (lv "go") (lv "x"))))
      case lower [ f ] of
        Left err -> fail (show err)
        Right prog -> case Array.head (liftedFuncs prog) of
          Nothing -> fail "expected a lifted code function for go"
          Just code -> Array.any selfApply (allRhs code.body) `shouldEqual` true

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
