-- | Lower the CoreFn AST to the backend IR (`PureScript.Backend.Wasm.IR`).
-- |
-- | This is the **Slice 1** lowering: the scalar `Int` world of Slice 0 plus
-- | algebraic data types and (single-scrutinee, unguarded) pattern matching,
-- | under the uniform `eqref` calling convention (ADR 0004) — every value is
-- | boxed, so each slot/parameter/result is `Boxed` and the codegen inserts the
-- | actual box/unbox.
-- |
-- | Three things drive the shape of this module:
-- |
-- |   * **Spine collection + saturation** (as in Slice 0): `f a b` is
-- |     `App (App f a) b`; we flatten and classify the head as a foreign
-- |     intrinsic, a data constructor, or a known top-level function.
-- |
-- |   * **A-normalization in continuation-passing style.** Slice 0 accumulated
-- |     `Let`s in a flat list, which cannot express the branching introduced by
-- |     `case`. Here every operand is lowered with a continuation
-- |     (`Atom -> Lower Block`), so the `Let`s a sub-expression needs wrap
-- |     exactly the continuation that uses them — and a branch's bindings stay
-- |     inside that branch.
-- |
-- |   * **Pattern-match compilation** (the decision tree of ADR 0003): a
-- |     `case` becomes a `Switch` on the scrutinee's constructor tag, and each
-- |     `ConstructorBinder`'s sub-binders become `RProjField` `Let`s. Slice 1
-- |     handles a single scrutinee, unguarded alternatives, and `Var`/wildcard
-- |     sub-binders only; nested sub-patterns, guards, literal binders, and
-- |     multiple scrutinees are deferred (reported, never mis-compiled).
module PureScript.Backend.Wasm.FromCoreFn
  ( lowerModule
  , LowerError(..)
  ) where

import Prelude

import Control.Monad.State (StateT, get, put, runStateT)
import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Show.Generic (genericShow)
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.IR (Atom(..), Block(..), Branch(..), FuncName(..), IRFunc, Intrinsic(..), Program, Rep(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.CoreFn (Bind(..), Module, Qualified(..))
import PureScript.CoreFn as C

-- | Slice 1 supports a strict subset; anything outside it is reported so the
-- | gap is explicit rather than silently mis-compiled.
data LowerError
  = UnsupportedExpr String
  | UnsupportedBinder String
  | UnknownVariable String
  | UnknownConstructor String
  | NotSaturated String Int Int -- name, expected arity, actual args
  | GuardedCaseUnsupported

derive instance eqLowerError :: Eq LowerError
derive instance genericLowerError :: Generic LowerError _
instance showLowerError :: Show LowerError where
  show = genericShow

-- | Lowering state: the next free local slot. Parameters occupy the slots below
-- | it; `Let`-bound temporaries take the rest. Unlike Slice 0 there is no flat
-- | binding accumulator — bindings are placed by the continuations directly.
type Lower a = StateT Int (Either LowerError) a

throw :: forall a. LowerError -> Lower a
throw = lift <<< Left

-- | Allocate a fresh local slot.
fresh :: Lower Slot
fresh = do
  n <- get
  put (n + 1)
  pure (Slot n)

-- | What a top-level identifier refers to.
type CtorInfo = { tag :: Int, arity :: Int }

-- | The local environment plus the read-only module facts the lowering needs.
-- | `locals` maps a CoreFn identifier to the `Atom` it denotes, so a let- or
-- | field-bound name can alias an existing slot/literal without a fresh copy.
type Env =
  { locals :: Object Atom
  , knownFuncs :: Object Int -- non-constructor top-level idents → arity
  , ctors :: Object CtorInfo -- constructor idents → tag + arity
  , moduleName :: Array String
  }

-- | The Slice 0/1 foreign-primitive table (ADR 0002's `ForeignProvider`, hard
-- | coded for now): a module-local foreign identifier → its machine op + arity.
foreignIntrinsic :: String -> Maybe (Tuple Intrinsic Int)
foreignIntrinsic = case _ of
  "addI" -> Just (Tuple IntAdd 2)
  "mulI" -> Just (Tuple IntMul 2)
  "subI" -> Just (Tuple IntSub 2)
  _ -> Nothing

qualifiedName :: forall a. Qualified a -> a
qualifiedName (Qualified _ a) = a

-- | Flatten a curried application spine: `App (App f a) b` → `f` with `[a, b]`.
collectApp :: C.Expr -> { head :: C.Expr, args :: Array C.Expr }
collectApp = go []
  where
  go acc = case _ of
    C.App _ f a -> go (Array.cons a acc) f
    other -> { head: other, args: acc }

-- | Peel leading lambdas into the parameter idents (outermost first) and body.
peelAbs :: C.Expr -> { params :: Array String, body :: C.Expr }
peelAbs = go []
  where
  go acc = case _ of
    C.Abs _ p b -> go (Array.snoc acc p) b
    body -> { params: acc, body }

-- | Bind an `Rhs` to a fresh slot and continue with the atom naming its result.
-- | Every slot is `Boxed` under the eqref convention (ADR 0004).
bindRhs :: Rhs -> (Atom -> Lower Block) -> Lower Block
bindRhs rhs k = do
  slot <- fresh
  rest <- k (AVar (Local slot))
  pure (Let slot Boxed rhs rest)

-- | Reduce an expression to a trivial `Atom`, threading any needed computation
-- | into `Let`s that wrap the continuation `k`.
lowerArg :: Env -> C.Expr -> (Atom -> Lower Block) -> Lower Block
lowerArg env expr k = case expr of
  C.Literal _ (C.LitInt n) -> k (ALitInt n)
  C.Literal _ _ -> throw (UnsupportedExpr "non-Int literal")
  C.Var _ (Qualified Nothing ident) ->
    case Object.lookup ident env.locals of
      Just atom -> k atom
      Nothing -> throw (UnknownVariable ident)
  -- A qualified name used as a value: only a nullary constructor is meaningful
  -- in Slice 1 (a bare partial reference is Slice 2).
  C.Var _ (Qualified (Just _) ident) ->
    case Object.lookup ident env.ctors of
      Just info
        | info.arity == 0 -> bindRhs (RMkData info.tag []) k
        | otherwise -> throw (UnsupportedExpr ("partially-applied constructor: " <> ident))
      Nothing -> throw (UnsupportedExpr ("unapplied top-level reference: " <> ident))
  C.App _ _ _ -> lowerApp env (collectApp expr) k
  C.Abs _ _ _ -> throw (UnsupportedExpr "lambda / closure (Slice 2)")
  _ -> throw (UnsupportedExpr "unsupported expression in argument position")

-- | Lower a left-to-right list of operands to atoms, then continue.
lowerArgs :: Env -> Array C.Expr -> (Array Atom -> Lower Block) -> Lower Block
lowerArgs env args k = case Array.uncons args of
  Nothing -> k []
  Just { head: e, tail } -> lowerArg env e \a -> lowerArgs env tail \as -> k (Array.cons a as)

-- | Lower an application spine to the call/allocation it denotes, classifying
-- | the head and checking saturation (ADR 0003), then continue with its result.
lowerApp :: Env -> { head :: C.Expr, args :: Array C.Expr } -> (Atom -> Lower Block) -> Lower Block
lowerApp env { head, args } k = case head of
  C.Var _ (Qualified (Just _) ident)
    | Just (Tuple intr arity) <- foreignIntrinsic ident ->
        saturated ident arity \atoms -> bindRhs (RPrim intr atoms) k
    | Just info <- Object.lookup ident env.ctors ->
        saturated ident info.arity \atoms -> bindRhs (RMkData info.tag atoms) k
    | Just arity <- Object.lookup ident env.knownFuncs ->
        saturated ident arity \atoms -> bindRhs (RCallKnown (funcName env.moduleName ident) atoms) k
    | otherwise -> throw (UnsupportedExpr ("unknown callee: " <> ident))
  _ -> throw (UnsupportedExpr "application of a non-name head (Slice 2)")
  where
  saturated name arity withAtoms =
    if Array.length args == arity then lowerArgs env args withAtoms
    else throw (NotSaturated name arity (Array.length args))

-- | Lower an expression in tail position to a complete `Block`.
lowerTail :: Env -> C.Expr -> Lower Block
lowerTail env = case _ of
  C.Case _ scrutinees alternatives -> lowerCase env scrutinees alternatives
  C.Let _ binds body -> lowerCoreLet env binds body
  expr -> lowerArg env expr \atom -> pure (Ret atom)

-- | A CoreFn `let` (non-recursive): bind each definition, extending the local
-- | environment, then lower the body. (purs hoists `case` scrutinees into such
-- | lets, e.g. `let v = Triple a b c in case v of …`.)
lowerCoreLet :: Env -> Array Bind -> C.Expr -> Lower Block
lowerCoreLet env binds body = case Array.uncons binds of
  Nothing -> lowerTail env body
  Just { head: NonRec _ ident e, tail } ->
    lowerArg env e \atom ->
      lowerCoreLet (env { locals = Object.insert ident atom env.locals }) tail body
  Just { head: Rec _ } -> throw (UnsupportedExpr "recursive let (Slice 2)")

-- | Compile a `case` into a `Switch` on the scrutinee's constructor tag.
lowerCase :: Env -> Array C.Expr -> Array C.CaseAlternative -> Lower Block
lowerCase env scrutinees alternatives = case scrutinees of
  [ scrutinee ] ->
    lowerArg env scrutinee \scrutAtom -> do
      branches <- traverse (lowerAlternative env scrutAtom) alternatives
      pure (Switch scrutAtom branches Nothing)
  _ -> throw (UnsupportedExpr "Slice 1 supports a single case scrutinee")

-- | One alternative → one `Branch`. The constructor's sub-binders become field
-- | projections bound inside the branch body.
lowerAlternative :: Env -> Atom -> C.CaseAlternative -> Lower Branch
lowerAlternative env scrutAtom alt = case alt.result of
  Left _ -> throw GuardedCaseUnsupported
  Right body -> case alt.binders of
    [ binder ] -> case binder of
      C.ConstructorBinder _ _ ctorNameQ subBinders -> do
        info <- requireCtor env (qualifiedName ctorNameQ)
        body' <- bindFields env scrutAtom 0 subBinders body
        pure (Branch info.tag body')
      _ -> throw (UnsupportedBinder "Slice 1 expects a constructor binder")
    _ -> throw (UnsupportedBinder "Slice 1 expects exactly one binder per alternative")

-- | Bind a constructor's sub-binders to its fields by position: a `VarBinder`
-- | becomes an `RProjField` `Let`, a `NullBinder` just advances the field index,
-- | and the body is lowered (in tail position) under the extended environment.
bindFields :: Env -> Atom -> Int -> Array C.Binder -> C.Expr -> Lower Block
bindFields env scrutAtom index subBinders body = case Array.uncons subBinders of
  Nothing -> lowerTail env body
  Just { head: b, tail } -> case b of
    C.NullBinder _ -> bindFields env scrutAtom (index + 1) tail body
    C.VarBinder _ name -> do
      slot <- fresh
      let env' = env { locals = Object.insert name (AVar (Local slot)) env.locals }
      rest <- bindFields env' scrutAtom (index + 1) tail body
      pure (Let slot Boxed (RProjField scrutAtom index) rest)
    _ -> throw (UnsupportedBinder "Slice 1 supports only var / wildcard sub-binders")

requireCtor :: Env -> String -> Lower CtorInfo
requireCtor env ctorName = case Object.lookup ctorName env.ctors of
  Just info -> pure info
  Nothing -> throw (UnknownConstructor ctorName)

-- | Qualify a top-level identifier into a globally-unique wasm function name.
funcName :: Array String -> String -> FuncName
funcName moduleName ident = FuncName (joinWith "." moduleName <> "." <> ident)

-- | Lower one top-level function definition to an `IRFunc`. Under the eqref
-- | convention every parameter and the result is `Boxed`; the host-facing `i32`
-- | interface is restored by the code generator's export wrappers.
lowerFunc :: ModuleInfo -> String -> C.Expr -> Either LowerError IRFunc
lowerFunc info ident expr = do
  let { params, body } = peelAbs expr
  let locals = Object.fromFoldable (Array.mapWithIndex (\i p -> Tuple p (AVar (Local (Slot i)))) params)
  let env = { locals, knownFuncs: info.knownFuncs, ctors: info.ctors, moduleName: info.moduleName }
  Tuple block localCount <- runStateT (lowerTail env body) (Array.length params)
  pure
    { name: funcName info.moduleName ident
    , params: const Boxed <$> params
    , result: Boxed
    , body: block
    , export: Just ident
    , localCount
    }

-- | Read-only facts about the module being lowered.
type ModuleInfo =
  { knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  , moduleName :: Array String
  }

-- | Collect the data constructors, assigning each a 0-based tag within its type
-- | (by order of appearance among the decls).
collectCtors :: Array Bind -> Object CtorInfo
collectCtors decls = (foldl step { counts: Object.empty, out: Object.empty } raw).out
  where
  raw = Array.mapMaybe ctorOf decls
  ctorOf = case _ of
    NonRec _ _ (C.Constructor _ typeName ctorName fieldNames) ->
      Just { typeName, ctorName, arity: Array.length fieldNames }
    _ -> Nothing
  step { counts, out } { typeName, ctorName, arity } =
    let
      tag = fromMaybe 0 (Object.lookup typeName counts)
    in
      { counts: Object.insert typeName (tag + 1) counts
      , out: Object.insert ctorName { tag, arity } out
      }

-- | The non-constructor top-level functions, mapped to their arity.
collectFuncs :: Array Bind -> Object Int
collectFuncs decls = Object.fromFoldable (Array.mapMaybe go decls)
  where
  go = case _ of
    NonRec _ ident expr
      | not (isConstructor expr) -> Just (Tuple ident (Array.length (peelAbs expr).params))
    _ -> Nothing

-- | Top-level definitions that become wasm functions: non-recursive,
-- | non-constructor bindings. Constructors are erased into `collectCtors`;
-- | recursive top-level groups are Slice 2.
functionDecls :: Array Bind -> Array (Tuple String C.Expr)
functionDecls = Array.mapMaybe case _ of
  NonRec _ ident expr | not (isConstructor expr) -> Just (Tuple ident expr)
  _ -> Nothing

isConstructor :: C.Expr -> Boolean
isConstructor = case _ of
  C.Constructor _ _ _ _ -> true
  _ -> false

-- | Lower a whole decoded CoreFn module to a Slice 1 IR `Program`.
lowerModule :: Module -> Either LowerError Program
lowerModule m = do
  let info = { knownFuncs: collectFuncs m.decls, ctors: collectCtors m.decls, moduleName: m.name }
  funcs <- traverse (\(Tuple ident expr) -> lowerFunc info ident expr) (functionDecls m.decls)
  pure { funcs }
