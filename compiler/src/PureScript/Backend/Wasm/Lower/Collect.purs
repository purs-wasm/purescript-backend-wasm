-- | The lowering's link-time pre-pass: pure scans over every MIR module that build
-- | the symbol tables the lowering reads (`ModuleInfo`) and decide which functions
-- | are reachable from the entry roots (the tree-shaking, ADR 0009). Nothing here
-- | lowers anything — these are the facts gathered *before* lowering.
module PureScript.Backend.Wasm.Lower.Collect
  ( collectCtors
  , collectEnumCtors
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
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (Rep(..))
import PureScript.Backend.Wasm.Lower.Types (CtorInfo, peelAbs, qualifiedKey)
import PureScript.Backend.Wasm.MiddleEnd.IR (Bind(..), Module)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Meta(..), Qualified(..))

-- | Collect the data constructors of every module, keyed by qualified name and
-- | assigning each a 0-based tag within its (qualified) type.
collectCtors :: Object (Array Rep) -> Array Module -> Object CtorInfo
collectCtors fieldReps modules = (foldl perModule { counts: Object.empty, out: Object.empty } modules).out
  where
  perModule acc m = foldl (step m.name) acc (Array.mapMaybe ctorOf m.decls)
  ctorOf = case _ of
    NonRec _ _ (M.Constructor typeName ctorName fieldNames) ->
      Just { typeName, ctorName, arity: Array.length fieldNames }
    _ -> Nothing
  step moduleName { counts, out } { typeName, ctorName, arity } =
    let
      typeKey = qualifiedKey moduleName typeName
      ctorKey = qualifiedKey moduleName ctorName
      tag = fromMaybe 0 (Object.lookup typeKey counts)
      -- the externs-derived field reps, but only when they agree with the arity the
      -- CoreFn reports — otherwise fall back to all-boxed (correct, just unoptimised)
      reps = case Object.lookup ctorKey fieldReps of
        Just rs | Array.length rs == arity -> rs
        _ -> Array.replicate arity Boxed
    in
      { counts: Object.insert typeKey (tag + 1) counts
      , out: Object.insert ctorKey { tag, arity, fieldReps: reps } out
      }

-- | The constructors of every **enum-like** type — a type whose every constructor
-- | is nullary (e.g. `Ordering`, `Unit`, `Data.Generic.Rep.NoArguments`, user
-- | enums). Their values are represented as allocation-free `i31ref` tags rather
-- | than heap `$ADT` structs (ADR 0013).
collectEnumCtors :: Array Module -> Object Unit
collectEnumCtors modules =
  Object.fromFoldable (Array.mapMaybe keepEnum entries)
  where
  entries = modules >>= \m -> Array.mapMaybe (ctorEntry m.name) m.decls
  -- the largest constructor arity seen for each (qualified) type
  typeArities = foldl (\acc e -> Object.alter (Just <<< maybe e.arity (max e.arity)) e.typeKey acc) Object.empty entries
  keepEnum e =
    if Object.lookup e.typeKey typeArities == Just 0 then Just (Tuple e.ctorKey unit)
    else Nothing
  ctorEntry moduleName = case _ of
    NonRec _ _ (M.Constructor typeName ctorName fieldNames) ->
      Just
        { typeKey: qualifiedKey moduleName typeName
        , ctorKey: qualifiedKey moduleName ctorName
        , arity: Array.length fieldNames
        }
    _ -> Nothing

-- | Flatten the top-level binding groups into `(ident, expr)` pairs. A `Rec`
-- | group is mutual recursion between top-level functions; since each becomes a
-- | module function called by name (`RCallKnown`), the recursion needs no
-- | special handling beyond compiling every member.
topLevelBindings :: Array Bind -> Array (Tuple String M.Expr)
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
functionDecls :: Object Unit -> Module -> Array (Tuple String M.Expr)
functionDecls dictCtors m =
  Array.filter
    (\(Tuple ident expr) -> not (isConstructor expr) && not (Object.member (qualifiedKey m.name ident) dictCtors))
    (topLevelBindings m.decls)

isConstructor :: M.Expr -> Boolean
isConstructor = case _ of
  M.Constructor _ _ _ -> true
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
    NonRec (Just IsTypeClassConstructor) ident _ -> Just (Tuple (qualifiedKey moduleName ident) unit)
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
    M.Lit (LitObject kvs) -> kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v)
    M.Lit (LitArray es) -> es >>= exprLabels
    M.Lit _ -> []
    M.Constructor _ _ _ -> []
    M.Accessor l e -> Array.cons l (exprLabels e)
    M.Update e copyFields kvs ->
      exprLabels e <> fromMaybe [] copyFields <> (kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v))
    M.Abs _ b -> exprLabels b
    M.App f args -> exprLabels f <> (args >>= exprLabels)
    M.Perform e -> exprLabels e
    M.Var _ -> []
    M.Case ss alts -> (ss >>= exprLabels) <> (alts >>= altLabels)
    M.Let binds b -> (binds >>= bindLabels) <> exprLabels b
  altLabels alt =
    (alt.binders >>= binderLabels)
      <> case alt.result of
        Right e -> exprLabels e
        Left guards -> guards >>= \g -> exprLabels g.guard <> exprLabels g.expression
  -- the labels a record pattern (`{ l: … }`) projects, recursing into nested binders
  binderLabels = case _ of
    LiteralBinder _ (LitObject fields) -> fields >>= \(Tuple l b) -> Array.cons l (binderLabels b)
    LiteralBinder _ (LitArray bs) -> bs >>= binderLabels
    ConstructorBinder _ _ _ bs -> bs >>= binderLabels
    NamedBinder _ _ b -> binderLabels b
    _ -> []

-- | The module-qualified names of the top-level bindings an expression references
-- | (`Qualified (Just module) ident` `Var`s), used for reachability.
qualifiedRefs :: M.Expr -> Array String
qualifiedRefs = go
  where
  go = case _ of
    M.Var (Qualified (Just m) ident) -> [ qualifiedKey m ident ]
    M.Var _ -> []
    M.Lit (LitArray es) -> es >>= go
    M.Lit (LitObject kvs) -> kvs >>= \(Tuple _ v) -> go v
    M.Lit _ -> []
    M.Constructor _ _ _ -> []
    M.Accessor _ e -> go e
    M.Update e _ kvs -> go e <> (kvs >>= \(Tuple _ v) -> go v)
    M.Abs _ b -> go b
    M.App f args -> go f <> (args >>= go)
    M.Perform e -> go e
    M.Case ss alts -> (ss >>= go) <> (alts >>= altRefs)
    M.Let binds b -> (binds >>= bindRefs) <> go b
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
reachableFunctions :: Object M.Expr -> Array String -> Object Unit
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
