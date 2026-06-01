-- | Unit tests for the CoreFn → IR lowering, focused on closure conversion
-- | (Slice 2): lambda lifting, free-variable capture, `EnvField` reads, and the
-- | known-call vs unknown-apply distinction. Small CoreFn modules are built by
-- | hand and lowered, and the resulting IR is inspected structurally (rather
-- | than by exact slot numbers, which would be brittle).
module Test.Unit.PureScript.Backend.Wasm.Lower (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower (LowerError, lowerModule)
import PureScript.Backend.Wasm.IR (Atom(..), AnfExpr(..), Branch(..), IRFunc, LitBranch(..), LitPat(..), Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))
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

litInt :: Int -> CF.Expr
litInt n = CF.Literal ann (CF.LitInt n)

-- | `case scrutinee of <alternatives>`.
caseOf :: CF.Expr -> Array CF.CaseAlternative -> CF.Expr
caseOf scrutinee alternatives = CF.Case ann [ scrutinee ] alternatives

-- | An `Int`-literal alternative `n -> body`.
intAlt :: Int -> CF.Expr -> CF.CaseAlternative
intAlt n body = { binders: [ CF.LiteralBinder ann (CF.LitInt n) ], result: Right body }

-- | A `Boolean`-literal alternative `b -> body`.
boolAlt :: Boolean -> CF.Expr -> CF.CaseAlternative
boolAlt b body = { binders: [ CF.LiteralBinder ann (CF.LitBoolean b) ], result: Right body }

-- | A `String`-literal alternative `"s" -> body`.
strAlt :: String -> CF.Expr -> CF.CaseAlternative
strAlt s body = { binders: [ CF.LiteralBinder ann (CF.LitString s) ], result: Right body }

-- | A wildcard alternative `_ -> body`.
wildAlt :: CF.Expr -> CF.CaseAlternative
wildAlt body = { binders: [ CF.NullBinder ann ], result: Right body }

litStr :: String -> CF.Expr
litStr s = CF.Literal ann (CF.LitString s)

-- | A record literal `{ label: expr, … }`.
litObj :: Array (Tuple String CF.Expr) -> CF.Expr
litObj fields = CF.Literal ann (CF.LitObject fields)

-- | `record.label`.
accessor :: String -> CF.Expr -> CF.Expr
accessor label record = CF.Accessor ann label record

-- | An annotation carrying compiler metadata.
annMeta :: CF.Meta -> CF.Ann
annMeta m = ann { meta = Just m }

-- | A type-class dictionary constructor declaration (a newtype identity tagged
-- | `IsTypeClassConstructor`, as purs emits).
dictCtorDecl :: String -> CF.Bind
dictCtorDecl name = CF.NonRec (annMeta CF.IsTypeClassConstructor) name (lam "x" (lv "x"))

-- | `case scrutinee of NtCtor v -> body` — a newtype unwrap (binder tagged
-- | `IsNewtype`), the shape a type-class method accessor compiles from.
newtypeCase :: String -> CF.Expr -> String -> CF.Expr -> CF.Expr
newtypeCase ctorName scrutinee var body =
  CF.Case ann [ scrutinee ]
    [ { binders:
          [ CF.ConstructorBinder (annMeta CF.IsNewtype)
              (CF.Qualified (Just [ "T" ]) ctorName)
              (CF.Qualified (Just [ "T" ]) ctorName)
              [ CF.VarBinder ann var ]
          ]
      , result: Right body
      }
    ]

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
  LitSwitch _ branches dflt ->
    (branches >>= \(LitBranch _ b) -> allRhs b) <> maybe [] allRhs dflt
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
  RMkRecord pairs -> map (\(Tuple _ a) -> a) pairs
  RProjLabel a _ -> [ a ]

-- | Every `Atom` appearing in a block.
blockAtoms :: AnfExpr -> Array Atom
blockAtoms = case _ of
  Return a -> [ a ]
  Let _ _ rhs k -> rhsAtoms rhs <> blockAtoms k
  Switch s branches dflt ->
    Array.cons s ((branches >>= \(Branch _ b) -> blockAtoms b) <> maybe [] blockAtoms dflt)
  LitSwitch s branches dflt ->
    Array.cons s ((branches >>= \(LitBranch _ b) -> blockAtoms b) <> maybe [] blockAtoms dflt)
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

-- | The label-id lists of every `RMkRecord` in a block.
recordLabelIds :: AnfExpr -> Array (Array Int)
recordLabelIds b = Array.mapMaybe idsOf (allRhs b)
  where
  idsOf = case _ of
    RMkRecord pairs -> Just (map (\(Tuple labelId _) -> labelId) pairs)
    _ -> Nothing

-- | The label ids of every `RProjLabel` in a block.
projLabelIds :: AnfExpr -> Array Int
projLabelIds b = Array.mapMaybe idOf (allRhs b)
  where
  idOf = case _ of
    RProjLabel _ labelId -> Just labelId
    _ -> Nothing

-- | The argument counts of every `RCallKnown` in a block.
callKnownArities :: AnfExpr -> Array Int
callKnownArities b = Array.mapMaybe arityOf (allRhs b)
  where
  arityOf = case _ of
    RCallKnown _ args -> Just (Array.length args)
    _ -> Nothing

-- | The first `LitSwitch` reachable along the `Let` spine: its patterns (in
-- | order) and whether it has a default arm.
litSwitchOf :: AnfExpr -> Maybe { pats :: Array LitPat, hasDefault :: Boolean }
litSwitchOf = case _ of
  LitSwitch _ branches dflt -> Just { pats: map (\(LitBranch p _) -> p) branches, hasDefault: isJust dflt }
  Let _ _ _ k -> litSwitchOf k
  _ -> Nothing

hasSwitch :: AnfExpr -> Boolean
hasSwitch = case _ of
  Switch _ _ _ -> true
  LitSwitch _ _ _ -> true
  Let _ _ _ k -> hasSwitch k
  LetRec _ k -> hasSwitch k
  Return _ -> false

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
