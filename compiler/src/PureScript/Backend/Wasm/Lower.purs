-- | Lower the CoreFn AST to the backend IR (`PureScript.Backend.Wasm.IR`).
-- |
-- | This is the **Slice 2** lowering: Slice 0/1 (scalar Int, ADTs, pattern
-- | matching) plus **closures**, under the uniform `eqref` convention
-- | (ADR 0004) and eval/apply (ADR 0003). Scope is *full-apply only* — closures
-- | are created and applied exactly; partial application of multi-argument
-- | functions and recursive `let` are reported, not compiled.
-- |
-- | The Slice 2 additions:
-- |
-- |   * **Lambda lifting / closure conversion.** A `C.Abs` is lifted to a
-- |     top-level code function `$codeN(closure, arg)`; its free local variables
-- |     are captured into the closure's environment, and the lifted body reads
-- |     them back as `EnvField`s. Lifted functions accumulate in the lowering
-- |     state and are appended to the program.
-- |
-- |   * **Unknown application.** When an application head is not a known
-- |     intrinsic / constructor / top-level function (i.e. it is a local closure
-- |     value or a lambda), it lowers to `RApply` — a `call_ref` through the
-- |     closure (ADR 0003 eval/apply), one argument at a time.
module PureScript.Backend.Wasm.Lower
  ( lowerModule
  , module ReExport
  ) where

import Prelude

import Control.Monad.State (gets, modify_, runStateT)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.FreeVars (freeVars)
import PureScript.Backend.Wasm.Lower.Monad (Lower, LowerError(..), fresh, throw)
import PureScript.Backend.Wasm.Lower.Monad (LowerError(..)) as ReExport
import PureScript.Backend.Wasm.IR (Atom(..), AnfExpr(..), Branch(..), FuncName(..), IRFunc, Intrinsic(..), Program, Rep(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.CoreFn (Bind(..), Module, Qualified(..))
import PureScript.CoreFn as C

type CtorInfo = { tag :: Int, arity :: Int }

-- | Read-only facts about the module being lowered.
type ModuleInfo =
  { knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  , moduleName :: Array String
  }

-- | The local environment plus the module facts. `locals` maps a CoreFn
-- | identifier to the `Atom` it denotes (a local slot, or — inside a lifted code
-- | function — a captured `EnvField`).
type Env =
  { locals :: Object Atom
  , knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  , moduleName :: Array String
  }

-- | The Slice 0/1/2 foreign-primitive table (ADR 0002's `ForeignProvider`, hard
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

resolveLocal :: Env -> String -> Lower Atom
resolveLocal env ident = case Object.lookup ident env.locals of
  Just atom -> pure atom
  Nothing -> throw (UnknownVariable ident)

-- | Bind an `Rhs` to a fresh slot (always `Boxed` under ADR 0004) and continue
-- | with the atom naming its result.
bindRhs :: Rhs -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
bindRhs rhs k = do
  slot <- fresh
  rest <- k (AVar (Local slot))
  pure (Let slot Boxed rhs rest)

-- | Reduce an expression to a trivial `Atom`, threading any computation into
-- | `Let`s that wrap the continuation `k`.
lowerArg :: Env -> C.Expr -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArg env expr k = case expr of
  C.Literal _ (C.LitInt n) -> k (ALitInt n)
  C.Literal _ _ -> throw (UnsupportedExpr "non-Int literal")
  C.Var _ (Qualified Nothing ident) -> resolveLocal env ident >>= k
  C.Var _ (Qualified (Just _) ident) -> case Object.lookup ident env.ctors of
    Just info
      | info.arity == 0 -> bindRhs (RMkData info.tag []) k
      | otherwise -> throw (UnsupportedExpr ("partially-applied constructor: " <> ident))
    Nothing -> throw (UnsupportedExpr ("unapplied top-level reference: " <> ident))
  C.App _ _ _ -> lowerApp env (collectApp expr) k
  C.Abs _ param body -> do
    { codeName, captures } <- liftLambda env param body
    bindRhs (RMkClosure codeName captures) k
  _ -> throw (UnsupportedExpr "unsupported expression in argument position")

-- | Lower a left-to-right list of operands to atoms, then continue.
lowerArgs :: Env -> Array C.Expr -> (Array Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArgs env args k = case Array.uncons args of
  Nothing -> k []
  Just { head: e, tail } -> lowerArg env e \a -> lowerArgs env tail \as -> k (Array.cons a as)

-- | Lower an application spine. A known intrinsic / constructor / top-level
-- | function applied saturated is a direct primitive / allocation / call; any
-- | other head (a local closure value or a lambda) is an `RApply` via
-- | `call_ref`.
lowerApp :: Env -> { head :: C.Expr, args :: Array C.Expr } -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerApp env { head, args } k = case head of
  C.Var _ (Qualified (Just _) ident)
    | Just (Tuple intr arity) <- foreignIntrinsic ident ->
        saturated ident arity \atoms -> bindRhs (RPrim intr atoms) k
    | Just info <- Object.lookup ident env.ctors ->
        saturated ident info.arity \atoms -> bindRhs (RMkData info.tag atoms) k
    | Just arity <- Object.lookup ident env.knownFuncs ->
        saturated ident arity \atoms -> bindRhs (RCallKnown (funcName env.moduleName ident) atoms) k
    | otherwise -> throw (UnsupportedExpr ("unknown callee: " <> ident))
  _ ->
    lowerArg env head \fAtom ->
      lowerArgs env args \atoms ->
        applyChain fAtom atoms k
  where
  saturated name arity withAtoms =
    if Array.length args == arity then lowerArgs env args withAtoms
    else throw (NotSaturated name arity (Array.length args))

-- | Apply a closure atom to a list of argument atoms one at a time, each a
-- | single-argument `RApply` whose result feeds the next (arity-1 closures).
applyChain :: Atom -> Array Atom -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
applyChain f args k = case Array.uncons args of
  Nothing -> k f
  Just { head: a, tail } -> bindRhs (RApply f a) \r -> applyChain r tail k

-- | Lift a `C.Abs` to a top-level code function and return its name plus the
-- | atoms to capture (the lambda's free locals, resolved in the current scope).
liftLambda :: Env -> String -> C.Expr -> Lower { codeName :: FuncName, captures :: Array Atom }
liftLambda env param body = do
  let frees = freeVars [ param ] body
  captures <- traverse (resolveLocal env) frees
  n <- gets _.nextCode
  modify_ _ { nextCode = n + 1 }
  let codeName = funcName env.moduleName ("$code" <> show n)
  -- The code function's locals: slot 0 = the closure, slot 1 = the argument;
  -- captured frees are read positionally from the closure environment.
  let
    codeLocals = Object.fromFoldable
      ( Array.cons (Tuple param (AVar (Local (Slot 1))))
          (Array.mapWithIndex (\i f -> Tuple f (AVar (EnvField i))) frees)
      )
  let codeEnv = env { locals = codeLocals }
  saved <- gets _.slot
  modify_ _ { slot = 2 }
  codeAnfExpr <- lowerTail codeEnv body
  codeCount <- gets _.slot
  modify_ _ { slot = saved }
  modify_ \s -> s
    { lifted = Array.snoc s.lifted
        { name: codeName
        , params: [ CloRef, Boxed ] -- (ref $Clo), then the eqref argument
        , result: Boxed
        , body: codeAnfExpr
        , export: Nothing
        , localCount: codeCount
        }
    }
  pure { codeName, captures }

-- | Lower an expression in tail position to a complete `AnfExpr`.
lowerTail :: Env -> C.Expr -> Lower AnfExpr
lowerTail env = case _ of
  C.Case _ scrutinees alternatives -> lowerCase env scrutinees alternatives
  C.Let _ binds body -> lowerCoreLet env binds body
  expr -> lowerArg env expr \atom -> pure (Return atom)

-- | A CoreFn `let` (non-recursive): bind each definition, extending the local
-- | environment, then lower the body. (purs hoists `case` scrutinees here.)
lowerCoreLet :: Env -> Array Bind -> C.Expr -> Lower AnfExpr
lowerCoreLet env binds body = case Array.uncons binds of
  Nothing -> lowerTail env body
  Just { head: NonRec _ ident e, tail } ->
    lowerArg env e \atom ->
      lowerCoreLet (env { locals = Object.insert ident atom env.locals }) tail body
  Just { head: Rec _ } -> throw (UnsupportedExpr "recursive let (deferred)")

-- | Compile a `case` into a `Switch` on the scrutinee's constructor tag.
lowerCase :: Env -> Array C.Expr -> Array C.CaseAlternative -> Lower AnfExpr
lowerCase env scrutinees alternatives = case scrutinees of
  [ scrutinee ] ->
    lowerArg env scrutinee \scrutAtom -> do
      branches <- traverse (lowerAlternative env scrutAtom) alternatives
      pure (Switch scrutAtom branches Nothing)
  _ -> throw (UnsupportedExpr "Slice 1 supports a single case scrutinee")

-- | One alternative → one `Branch`, with the constructor's sub-binders bound as
-- | field projections inside the branch body.
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

-- | Bind a constructor's sub-binders to its fields by position.
bindFields :: Env -> Atom -> Int -> Array C.Binder -> C.Expr -> Lower AnfExpr
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

-- | Lower one top-level function definition to an `IRFunc` (eqref convention).
lowerTopFunc :: ModuleInfo -> Tuple String C.Expr -> Lower IRFunc
lowerTopFunc info (Tuple ident expr) = do
  let { params, body } = peelAbs expr
  let locals = Object.fromFoldable (Array.mapWithIndex (\i p -> Tuple p (AVar (Local (Slot i)))) params)
  let env = { locals, knownFuncs: info.knownFuncs, ctors: info.ctors, moduleName: info.moduleName }
  modify_ _ { slot = Array.length params }
  block <- lowerTail env body
  count <- gets _.slot
  pure
    { name: funcName info.moduleName ident
    , params: const Boxed <$> params
    , result: Boxed
    , body: block
    , export: Just ident
    , localCount: count
    }

-- | Collect the data constructors, assigning each a 0-based tag within its type.
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
-- | non-constructor bindings.
functionDecls :: Array Bind -> Array (Tuple String C.Expr)
functionDecls = Array.mapMaybe case _ of
  NonRec _ ident expr | not (isConstructor expr) -> Just (Tuple ident expr)
  _ -> Nothing

isConstructor :: C.Expr -> Boolean
isConstructor = case _ of
  C.Constructor _ _ _ _ -> true
  _ -> false

-- | Lower a whole decoded CoreFn module to a Slice 2 IR `Program`. The lifted
-- | code functions accumulated during lowering are appended to the program's
-- | functions.
lowerModule :: Module -> Either LowerError Program
lowerModule m = do
  let
    info =
      { knownFuncs: collectFuncs m.decls
      , ctors: collectCtors m.decls
      , moduleName: m.name
      }
  Tuple funcs st <- runStateT
    (traverse (lowerTopFunc info) (functionDecls m.decls))
    { slot: 0, lifted: [], nextCode: 0 }
  pure { funcs: funcs <> st.lifted }
