-- | Shared CoreFn builders and IR-inspection helpers for the lowering unit tests
-- | (`Test.Unit.…​.Lower` and `Test.Unit.…​.Lower.Match`). Small CoreFn modules are
-- | built by hand and lowered, then the resulting IR is inspected structurally
-- | (rather than by exact slot numbers, which would be brittle).
module Test.Unit.PureScript.Backend.Wasm.Lower.Common where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (Atom(..), AnfExpr(..), Branch(..), ForeignImport, FuncName(..), IRFunc, LitBranch(..), LitPat, Program, RecBind(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.Backend.Wasm.Lower (LowerError, lowerModule, lowerModules)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translModule)
import PureScript.CoreFn as CF

-- --- CoreFn builders (zero annotation) --------------------------------------

ann :: CF.Ann
ann = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

-- | An annotation carrying compiler metadata.
annMeta :: CF.Meta -> CF.Ann
annMeta m = ann { meta = Just m }

-- | A local variable reference.
lv :: String -> CF.Expr
lv x = CF.Var ann (CF.Qualified Nothing x)

-- | A module-qualified reference (foreign primitive or top-level name).
qv :: String -> CF.Expr
qv x = CF.Var ann (CF.Qualified (Just [ "T" ]) x)

-- | A reference qualified to another module (`Mod.ident`).
qvIn :: String -> String -> CF.Expr
qvIn modName x = CF.Var ann (CF.Qualified (Just [ modName ]) x)

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

litStr :: String -> CF.Expr
litStr s = CF.Literal ann (CF.LitString s)

-- | A record literal `{ label: expr, … }`.
litObj :: Array (Tuple String CF.Expr) -> CF.Expr
litObj fields = CF.Literal ann (CF.LitObject fields)

-- | `case scrutinee of <alternatives>`.
caseOf :: CF.Expr -> Array CF.CaseAlternative -> CF.Expr
caseOf scrutinee alternatives = CF.Case ann [ scrutinee ] alternatives

-- | `case s1, s2 of <alternatives>` — a two-scrutinee match.
case2 :: CF.Expr -> CF.Expr -> Array CF.CaseAlternative -> CF.Expr
case2 s1 s2 alternatives = CF.Case ann [ s1, s2 ] alternatives

-- | An `Int`-literal alternative `n -> body`.
intAlt :: Int -> CF.Expr -> CF.CaseAlternative
intAlt n body = { binders: [ CF.LiteralBinder ann (CF.LitInt n) ], result: Right body }

-- | A `Boolean`-literal alternative `b -> body`.
boolAlt :: Boolean -> CF.Expr -> CF.CaseAlternative
boolAlt b body = { binders: [ CF.LiteralBinder ann (CF.LitBoolean b) ], result: Right body }

-- | A `String`-literal alternative `"s" -> body`.
strAlt :: String -> CF.Expr -> CF.CaseAlternative
strAlt s body = { binders: [ CF.LiteralBinder ann (CF.LitString s) ], result: Right body }

-- | A constructor alternative `Ctor sub… -> body` (type `Ty`, module `T`).
ctorAlt :: String -> Array CF.Binder -> CF.Expr -> CF.CaseAlternative
ctorAlt name subBinders body = { binders: [ ctorBinder name subBinders ], result: Right body }

-- | A wildcard alternative `_ -> body`.
wildAlt :: CF.Expr -> CF.CaseAlternative
wildAlt body = { binders: [ CF.NullBinder ann ], result: Right body }

-- | A single-binder alternative `binder -> body`.
binderAlt :: CF.Binder -> CF.Expr -> CF.CaseAlternative
binderAlt binder body = { binders: [ binder ], result: Right body }

-- | A guarded alternative `binder | guard -> result`.
guardedAlt :: CF.Binder -> CF.Expr -> CF.Expr -> CF.CaseAlternative
guardedAlt binder guard expression = { binders: [ binder ], result: Left [ { guard, expression } ] }

-- | A constructor binder `Ctor sub…` (type `Ty`, module `T`).
ctorBinder :: String -> Array CF.Binder -> CF.Binder
ctorBinder = ctorBinderT "Ty"

-- | A constructor binder for an explicit type name.
ctorBinderT :: String -> String -> Array CF.Binder -> CF.Binder
ctorBinderT typeName name subBinders =
  CF.ConstructorBinder ann (CF.Qualified (Just [ "T" ]) typeName) (CF.Qualified (Just [ "T" ]) name) subBinders

-- | A two-binder alternative `b1, b2 -> body`.
alt2 :: CF.Binder -> CF.Binder -> CF.Expr -> CF.CaseAlternative
alt2 b1 b2 body = { binders: [ b1, b2 ], result: Right body }

nullBinder :: CF.Binder
nullBinder = CF.NullBinder ann

varBinder :: String -> CF.Binder
varBinder = CF.VarBinder ann

-- | An as-pattern binder `name@inner`.
namedBinder :: String -> CF.Binder -> CF.Binder
namedBinder name inner = CF.NamedBinder ann name inner

-- | An `Int`-literal binder `n` (the pattern shape inside a multi-scrutinee case).
intLitBinder :: Int -> CF.Binder
intLitBinder n = CF.LiteralBinder ann (CF.LitInt n)

-- | An array-literal binder `[ b… ]` (matches arrays of exactly that length).
arrayBinder :: Array CF.Binder -> CF.Binder
arrayBinder subs = CF.LiteralBinder ann (CF.LitArray subs)

-- | `record.label`.
accessor :: String -> CF.Expr -> CF.Expr
accessor label record = CF.Accessor ann label record

-- | A record update `record { l = v, … }`; `copyFields` are the untouched labels.
objUpdate :: CF.Expr -> Array String -> Array (Tuple String CF.Expr) -> CF.Expr
objUpdate record copyFields updates = CF.ObjectUpdate ann record (Just copyFields) updates

-- | A *polymorphic* record update over an open row: the untouched fields are unknown
-- | (`copyFields = Nothing`), so it lowers to a runtime copy-and-set chain (ADR 0023).
objUpdatePoly :: CF.Expr -> Array (Tuple String CF.Expr) -> CF.Expr
objUpdatePoly record updates = CF.ObjectUpdate ann record Nothing updates

-- | A record-pattern alternative `{ l: subBinder, … } -> body`.
recAlt :: Array (Tuple String CF.Binder) -> CF.Expr -> CF.CaseAlternative
recAlt fields body = { binders: [ CF.LiteralBinder ann (CF.LitObject fields) ], result: Right body }

-- | A type-class dictionary constructor declaration (a newtype identity tagged
-- | `IsTypeClassConstructor`, as purs emits).
dictCtorDecl :: String -> CF.Bind
dictCtorDecl name = CF.NonRec (annMeta CF.IsTypeClassConstructor) name (lam "x" (lv "x"))

-- | `case scrutinee of NtCtor v -> body` — a newtype unwrap (binder tagged
-- | `IsNewtype`), the shape a type-class method accessor compiles from.
newtypeCase :: String -> CF.Expr -> String -> CF.Expr -> CF.Expr
newtypeCase ctorName scrutinee var body =
  CF.Case ann [ scrutinee ]
    [ { binders: [ newtypeBinder ctorName [ CF.VarBinder ann var ] ], result: Right body } ]

-- | A newtype constructor binder (tagged `IsNewtype`, so it is erased).
newtypeBinder :: String -> Array CF.Binder -> CF.Binder
newtypeBinder ctorName subBinders =
  CF.ConstructorBinder (annMeta CF.IsNewtype)
    (CF.Qualified (Just [ "T" ]) ctorName)
    (CF.Qualified (Just [ "T" ]) ctorName)
    subBinders

-- | A CoreFn module with the given name and decls.
moduleNamed :: Array String -> Array CF.Bind -> CF.Module
moduleNamed name decls =
  { name
  , path: "Module.purs"
  , builtWith: "0.15.16"
  , imports: []
  , exports: []
  , reExports: Object.empty
  , foreignNames: []
  , decls
  }

-- The lowering now consumes the MIR, so the test helpers translate their hand-built
-- CoreFn to MIR first (without the optimization passes — these test lowering alone).
lower :: Array CF.Bind -> Either LowerError Program
lower decls = lowerModule true (translModule (moduleNamed [ "T" ] decls))

lowerMany :: Array (Array String) -> Array CF.Module -> Either LowerError Program
lowerMany roots modules = lowerModules true Object.empty Object.empty Set.empty roots (map translModule modules)

-- | Lower a single `T` module with a foreign-import signature table (ADR 0014): a
-- | reference to a name in the table resolves to a host-import call
-- | (`RCallForeign`) rather than `UnsupportedExpr`.
lowerForeign :: Object ForeignImport -> Array CF.Bind -> Either LowerError Program
lowerForeign foreigns decls = lowerModules true Object.empty foreigns Set.empty [ [ "T" ] ] [ translModule (moduleNamed [ "T" ] decls) ]

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
  LetJoin _ _ producer k -> allRhs producer <> allRhs k

rhsAtoms :: Rhs -> Array Atom
rhsAtoms = case _ of
  RAtom a -> [ a ]
  RPrim _ as -> as
  RCallKnown _ as -> as
  RCallForeign _ as -> as
  RMkData _ _ as -> as
  RMkEnum _ -> []
  REnumTag a -> [ a ]
  RProjField a _ _ -> [ a ]
  RMkClosure _ as -> as
  RApply f a -> [ f, a ]
  RMkRecord pairs -> map (\(Tuple _ a) -> a) pairs
  RProjLabel a _ -> [ a ]
  RRecSet rec _ val -> [ rec, val ]
  RMkArray as -> as

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
  LetJoin _ _ producer k -> blockAtoms producer <> blockAtoms k

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
    RMkData tag _ _ -> Just tag
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

-- | The label ids of every `RRecSet` (copy-and-set) in a block, in order (ADR 0023).
recSetLabelIds :: AnfExpr -> Array Int
recSetLabelIds b = Array.mapMaybe idOf (allRhs b)
  where
  idOf = case _ of
    RRecSet _ labelId _ -> Just labelId
    _ -> Nothing

-- | The field indices of every `RProjField` in a block.
projFieldIndices :: AnfExpr -> Array Int
projFieldIndices b = Array.mapMaybe idxOf (allRhs b)
  where
  idxOf = case _ of
    RProjField _ _ idx -> Just idx
    _ -> Nothing

-- | The element counts of every `RMkArray` in a block.
arrayLengths :: AnfExpr -> Array Int
arrayLengths b = Array.mapMaybe lenOf (allRhs b)
  where
  lenOf = case _ of
    RMkArray as -> Just (Array.length as)
    _ -> Nothing

-- | The argument counts of every `RCallKnown` in a block.
callKnownArities :: AnfExpr -> Array Int
callKnownArities b = Array.mapMaybe arityOf (allRhs b)
  where
  arityOf = case _ of
    RCallKnown _ args -> Just (Array.length args)
    _ -> Nothing

-- | The (qualified) names called by every `RCallKnown` in a block.
callKnownNames :: AnfExpr -> Array String
callKnownNames b = Array.mapMaybe nameOf (allRhs b)
  where
  nameOf = case _ of
    RCallKnown (FuncName name) _ -> Just name
    _ -> Nothing

exportOf :: String -> Program -> Maybe (Maybe String)
exportOf name prog = _.export <$> Array.find (\fn -> fn.name == FuncName name) prog.funcs

-- | The first `LitSwitch` reachable along the `Let` spine: its patterns (in
-- | order) and whether it has a default arm.
litSwitchOf :: AnfExpr -> Maybe { pats :: Array LitPat, hasDefault :: Boolean }
litSwitchOf = case _ of
  LitSwitch _ branches dflt -> Just { pats: map (\(LitBranch p _) -> p) branches, hasDefault: isJust dflt }
  Let _ _ _ k -> litSwitchOf k
  -- an argument-position case lowers to a join point whose producer holds the switch (ADR 0022)
  LetJoin _ _ producer k -> case litSwitchOf producer of
    Just r -> Just r
    Nothing -> litSwitchOf k
  _ -> Nothing

-- | The first `Switch` reachable along the `Let` spine: its branch tags and
-- | whether it has a default arm.
switchOf :: AnfExpr -> Maybe { tags :: Array Int, hasDefault :: Boolean }
switchOf = case _ of
  Switch _ branches dflt -> Just { tags: map (\(Branch t _) -> t) branches, hasDefault: isJust dflt }
  Let _ _ _ k -> switchOf k
  _ -> Nothing

hasSwitch :: AnfExpr -> Boolean
hasSwitch = case _ of
  Switch _ _ _ -> true
  LitSwitch _ _ _ -> true
  Let _ _ _ k -> hasSwitch k
  LetRec _ k -> hasSwitch k
  LetJoin _ _ producer k -> hasSwitch producer || hasSwitch k
  Return _ -> false

-- | The scrutinee atom of every `Switch` / `LitSwitch` in the tree (one per
-- | decision node). Its length is the number of tag/value tests, and how often a
-- | given atom appears is how many times that scrutinee is examined.
switchScrutinees :: AnfExpr -> Array Atom
switchScrutinees = case _ of
  Return _ -> []
  Let _ _ _ k -> switchScrutinees k
  Switch s branches dflt ->
    Array.cons s ((branches >>= \(Branch _ b) -> switchScrutinees b) <> maybe [] switchScrutinees dflt)
  LitSwitch s branches dflt ->
    Array.cons s ((branches >>= \(LitBranch _ b) -> switchScrutinees b) <> maybe [] switchScrutinees dflt)
  LetRec _ k -> switchScrutinees k
  LetJoin _ _ producer k -> switchScrutinees producer <> switchScrutinees k

-- | The number of `LitSwitch` decision nodes in the tree.
countLitSwitches :: AnfExpr -> Int
countLitSwitches = case _ of
  Return _ -> 0
  Let _ _ _ k -> countLitSwitches k
  Switch _ branches dflt ->
    sumBranches branches + maybe 0 countLitSwitches dflt
  LitSwitch _ branches dflt ->
    1 + sumLitBranches branches + maybe 0 countLitSwitches dflt
  LetRec _ k -> countLitSwitches k
  LetJoin _ _ producer k -> countLitSwitches producer + countLitSwitches k
  where
  sumBranches = Array.foldl (\acc (Branch _ b) -> acc + countLitSwitches b) 0
  sumLitBranches = Array.foldl (\acc (LitBranch _ b) -> acc + countLitSwitches b) 0

isApply :: Rhs -> Boolean
isApply = case _ of
  RApply _ _ -> true
  _ -> false

isPrim :: Rhs -> Boolean
isPrim = case _ of
  RPrim _ _ -> true
  _ -> false

isCallForeign :: Rhs -> Boolean
isCallForeign = case _ of
  RCallForeign _ _ -> true
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
