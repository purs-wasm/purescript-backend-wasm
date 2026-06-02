-- | The lowering's link-time pre-pass: pure scans over every decoded CoreFn module
-- | that build the symbol tables the lowering reads (`ModuleInfo`) and decide which
-- | functions are reachable from the entry roots (the tree-shaking, ADR 0009).
-- | Nothing here lowers anything — these are the facts gathered *before* lowering.
module PureScript.Backend.Wasm.Lower.Collect
  ( collectCtors
  , collectFuncs
  , collectDictCtors
  , collectLabels
  , functionDecls
  , topLevelBindings
  , isConstructor
  , qualifiedRefs
  , reachableFunctions
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.Types (CtorInfo, peelAbs, qualifiedKey)
import PureScript.CoreFn (Bind(..), Module, Qualified(..))
import PureScript.CoreFn as C

-- | Collect the data constructors of every module, keyed by qualified name and
-- | assigning each a 0-based tag within its (qualified) type.
collectCtors :: Array Module -> Object CtorInfo
collectCtors modules = (foldl perModule { counts: Object.empty, out: Object.empty } modules).out
  where
  perModule acc m = foldl (step m.name) acc (Array.mapMaybe ctorOf m.decls)
  ctorOf = case _ of
    NonRec _ _ (C.Constructor _ typeName ctorName fieldNames) ->
      Just { typeName, ctorName, arity: Array.length fieldNames }
    _ -> Nothing
  step moduleName { counts, out } { typeName, ctorName, arity } =
    let
      typeKey = qualifiedKey moduleName typeName
      tag = fromMaybe 0 (Object.lookup typeKey counts)
    in
      { counts: Object.insert typeKey (tag + 1) counts
      , out: Object.insert (qualifiedKey moduleName ctorName) { tag, arity } out
      }

-- | Flatten the top-level binding groups into `(ident, expr)` pairs. A `Rec`
-- | group is mutual recursion between top-level functions; since each becomes a
-- | module function called by name (`RCallKnown`), the recursion needs no
-- | special handling beyond compiling every member.
topLevelBindings :: Array Bind -> Array (Tuple String C.Expr)
topLevelBindings = (_ >>= flatten)
  where
  flatten = case _ of
    NonRec _ ident expr -> [ Tuple ident expr ]
    Rec rs -> map (\r -> Tuple r.ident r.expr) rs

-- | Every module's non-constructor top-level functions, keyed by qualified name
-- | and mapped to arity. Dictionary constructors are excluded: they are newtype
-- | identities, erased at their use sites rather than emitted (ADR 0007).
collectFuncs :: Object Unit -> Array Module -> Object Int
collectFuncs dictCtors modules = Object.fromFoldable (modules >>= moduleFuncs)
  where
  moduleFuncs m = Array.mapMaybe (keep m.name) (topLevelBindings m.decls)
  keep moduleName (Tuple ident expr)
    | isConstructor expr || Object.member (qualifiedKey moduleName ident) dictCtors = Nothing
    | otherwise = Just (Tuple (qualifiedKey moduleName ident) (Array.length (peelAbs expr).params))

-- | One module's definitions that become wasm functions: every binding (including
-- | `Rec`-group members) that is neither a data constructor nor a (newtype-erased)
-- | dictionary constructor.
functionDecls :: Object Unit -> Module -> Array (Tuple String C.Expr)
functionDecls dictCtors m =
  Array.filter
    (\(Tuple ident expr) -> not (isConstructor expr) && not (Object.member (qualifiedKey m.name ident) dictCtors))
    (topLevelBindings m.decls)

isConstructor :: C.Expr -> Boolean
isConstructor = case _ of
  C.Constructor _ _ _ _ -> true
  _ -> false

-- | Every module's type-class dictionary constructors (decls tagged
-- | `IsTypeClassConstructor`), keyed by qualified name. Each is a newtype identity
-- | (`\x -> x`) wrapping the dictionary record, so its applications are erased
-- | (ADR 0007).
collectDictCtors :: Array Module -> Object Unit
collectDictCtors modules = Object.fromFoldable (modules >>= moduleDictCtors)
  where
  moduleDictCtors m = Array.mapMaybe (dictCtorOf m.name) m.decls
  dictCtorOf moduleName = case _ of
    NonRec ann ident _ | ann.meta == Just C.IsTypeClassConstructor -> Just (Tuple (qualifiedKey moduleName ident) unit)
    _ -> Nothing

-- | Intern every record/dictionary label across all modules to a unique `i32` id,
-- | assigned by sorted label order so the mapping is deterministic and shared:
-- | records built in one module and projected in another agree on a label's id.
collectLabels :: Array Module -> Object Int
collectLabels modules =
  Object.fromFoldable
    (Array.mapWithIndex (\i l -> Tuple l i) (Array.sort (Array.nub (modules >>= \m -> m.decls >>= bindLabels))))
  where
  bindLabels = case _ of
    NonRec _ _ e -> exprLabels e
    Rec rs -> rs >>= \r -> exprLabels r.expr
  exprLabels = case _ of
    C.Literal _ (C.LitObject kvs) -> kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v)
    C.Literal _ (C.LitArray es) -> es >>= exprLabels
    C.Literal _ _ -> []
    C.Constructor _ _ _ _ -> []
    C.Accessor _ l e -> Array.cons l (exprLabels e)
    C.ObjectUpdate _ e copyFields kvs ->
      exprLabels e <> fromMaybe [] copyFields <> (kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v))
    C.Abs _ _ b -> exprLabels b
    C.App _ f a -> exprLabels f <> exprLabels a
    C.Var _ _ -> []
    C.Case _ ss alts -> (ss >>= exprLabels) <> (alts >>= altLabels)
    C.Let _ binds b -> (binds >>= bindLabels) <> exprLabels b
  altLabels alt =
    (alt.binders >>= binderLabels)
      <> case alt.result of
        Right e -> exprLabels e
        Left guards -> guards >>= \g -> exprLabels g.guard <> exprLabels g.expression
  -- the labels a record pattern (`{ l: … }`) projects, recursing into nested binders
  binderLabels = case _ of
    C.LiteralBinder _ (C.LitObject fields) -> fields >>= \(Tuple l b) -> Array.cons l (binderLabels b)
    C.LiteralBinder _ (C.LitArray bs) -> bs >>= binderLabels
    C.ConstructorBinder _ _ _ bs -> bs >>= binderLabels
    C.NamedBinder _ _ b -> binderLabels b
    _ -> []

-- | The module-qualified names of the top-level bindings an expression references
-- | (`Qualified (Just module) ident` `Var`s), used for reachability.
qualifiedRefs :: C.Expr -> Array String
qualifiedRefs = go
  where
  go = case _ of
    C.Var _ (Qualified (Just m) ident) -> [ qualifiedKey m ident ]
    C.Var _ _ -> []
    C.Literal _ (C.LitArray es) -> es >>= go
    C.Literal _ (C.LitObject kvs) -> kvs >>= \(Tuple _ v) -> go v
    C.Literal _ _ -> []
    C.Constructor _ _ _ _ -> []
    C.Accessor _ _ e -> go e
    C.ObjectUpdate _ e _ kvs -> go e <> (kvs >>= \(Tuple _ v) -> go v)
    C.Abs _ _ b -> go b
    C.App _ f a -> go f <> go a
    C.Case _ ss alts -> (ss >>= go) <> (alts >>= altRefs)
    C.Let _ binds b -> (binds >>= bindRefs) <> go b
  altRefs alt = case alt.result of
    Right e -> go e
    Left guards -> guards >>= \g -> go g.guard <> go g.expression
  bindRefs = case _ of
    NonRec _ _ e -> go e
    Rec rs -> rs >>= \r -> go r.expr

-- | The set of function keys reachable from `roots`, following references through
-- | the `functions` table (a worklist closure). References to things outside the
-- | table — foreign primitives, data/dictionary constructors — are not followed,
-- | since those are not lowered as functions. This is the tree-shaking that lets a
-- | few `Prelude` functions be lowered without dragging in (and failing on) the
-- | rest of a module (ADR 0009).
reachableFunctions :: Object C.Expr -> Array String -> Object Unit
reachableFunctions functions roots = go (Object.fromFoldable (map (\k -> Tuple k unit) roots)) roots
  where
  go seen frontier = case Array.uncons frontier of
    Nothing -> seen
    Just { head: key, tail } -> case Object.lookup key functions of
      Nothing -> go seen tail
      Just expr ->
        let
          fresh = Array.filter (\k -> Object.member k functions && not (Object.member k seen))
            (Array.nub (qualifiedRefs expr))
        in
          go (foldl (\s k -> Object.insert k unit s) seen fresh) (tail <> fresh)
