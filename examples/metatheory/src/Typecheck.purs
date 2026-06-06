module Examples.Metatheory.Typecheck where

import Prelude

import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Except (Except, runExcept)
import Control.Monad.Reader (class MonadAsk, class MonadReader, ReaderT, ask, local, runReaderT)
import Control.Monad.State (StateT, evalStateT, get, modify_)
import Control.Monad.State.Class (class MonadState)
import Data.Array (foldl, uncons)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), isJust)
import Data.Show.Generic (genericShow)
import Data.Tuple (uncurry)
import Data.Tuple.Nested (type (/\), (/\))
import Examples.Metatheory.Primitive (Primitive(..))
import Examples.Metatheory.Syntax (Constant(..), Expr(..), Type_(..), Var(..))
import Fmt as Fmt

-- AST whose every node is annotated with its type
data TypedExpr
  = TxprLit Type_ Constant
  | TxprVar Type_ Var
  | TxprPrim Type_ Primitive (Array TypedExpr)
  | TxprAbs Type_ Var Type_ TypedExpr
  | TxprApp Type_ TypedExpr TypedExpr
  | TxprIf Type_ TypedExpr TypedExpr TypedExpr
  | TxprLet Type_ Var Type_ TypedExpr TypedExpr
  | TxprTyAbs Type_ Var TypedExpr
  | TxprTyApp Type_ TypedExpr Type_

-- | TxprLetrec Type_ Var Type_ TypedExpr TypedExpr

derive instance Generic TypedExpr _
derive instance Eq TypedExpr
instance Show TypedExpr where
  show te = genericShow te

data TypeError
  = WShadowing Var
  | ETypeMismatch Type_ Type_
  | ENotAFunction Type_
  | ENotAType Type_
  | EUnboundVariable Var
  | EUnboundTypeVariable Var
  | EUnexpectedForall
  | EPrimArityMismatch
  | EInvalidTypeApp Type_
  | EOtherError String

derive instance Generic TypeError _
instance Show TypeError where
  show te = genericShow te

data TypeEnv
  = TENil
  | TEVar Var Type_ TypeEnv
  | TETyVar Var TypeEnv

lookupEnv :: Var -> TypeEnv -> Maybe Type_
lookupEnv v = go
  where
  go = case _ of
    TENil -> Nothing
    TETyVar _ rest -> go rest
    TEVar x t rest
      | x == v -> Just t
      | otherwise -> go rest

emptyEnv :: TypeEnv
emptyEnv = TENil

extend :: Var -> Type_ -> TypeEnv -> TypeEnv
extend = TEVar

type TypingState =
  { nextMeta :: Int
  , warnings :: Array TypeError
  }

newtype TypingM a = TypingM (ReaderT TypeEnv (StateT TypingState (Except TypeError)) a)

derive newtype instance Functor TypingM
derive newtype instance Apply TypingM
derive newtype instance Applicative TypingM
derive newtype instance Bind TypingM
derive newtype instance Monad TypingM
derive newtype instance MonadAsk TypeEnv TypingM
derive newtype instance MonadReader TypeEnv TypingM
derive newtype instance MonadState TypingState TypingM
derive newtype instance MonadThrow TypeError TypingM

runTyping :: TypeEnv -> TypingState -> TypingM ~> Either TypeError
runTyping env s (TypingM m) = runExcept (evalStateT (runReaderT m env) s)

freshMeta :: TypingM Var
freshMeta = do
  { nextMeta: m } <- get
  modify_ (_ { nextMeta = m + 1 })
  pure (Var (Fmt.fmt @"?m{m}" { m }))

failwith :: forall a. TypeError -> TypingM a
failwith = throwError

warn :: TypeError -> TypingM Unit
warn w = modify_ \s -> s { warnings = s.warnings <> [ w ] }

lookup :: Var -> TypingM (Maybe Type_)
lookup v = ask <#> lookupEnv v

typeOf :: TypedExpr -> Type_
typeOf = case _ of
  TxprLit t _ -> t
  TxprVar t _ -> t
  TxprPrim t _ _ -> t
  TxprAbs t _ _ _ -> t
  TxprApp t _ _ -> t
  TxprIf t _ _ _ -> t
  TxprLet t _ _ _ _ -> t
  TxprTyAbs t _ _ -> t
  TxprTyApp t _ _ -> t

-- TxprLetrec t _ _ _ _ -> t

typeSubst :: Var -> Type_ -> Type_ -> Either TypeError Type_
typeSubst tv typ = case _ of
  TyInt -> pure TyInt
  TyBool -> pure TyBool
  TyVar tv'
    | tv' == tv -> pure typ
    | otherwise -> pure $ TyVar tv'
  TyArr t1 t2 -> TyArr <$> typeSubst tv typ t1 <*> typeSubst tv typ t2
  TyPi tv' t1
    | tv' /= tv -> TyPi tv' <$> typeSubst tv typ t1
    | otherwise -> pure $ TyPi tv' t1

typing :: Expr -> TypingM TypedExpr
typing = case _ of
  ExprLit (CstInt n) -> pure (TxprLit TyInt (CstInt n))
  ExprLit (CstBool b) -> pure (TxprLit TyBool (CstBool b))

  ExprVar v -> lookup v >>= case _ of
    Just t -> pure (TxprVar t v)
    Nothing -> failwith (EUnboundVariable v)

  ExprAbs v t1 e -> do
    whenM (isJust <$> (lookup v)) do
      warn (WShadowing v)
    te <- withExtends [ v /\ t1 ] (typing e)
    pure (TxprAbs (TyArr t1 (typeOf te)) v t1 te)

  ExprApp e1 e2 -> do
    te1 <- typing e1
    te2 <- typing e2
    case typeOf te1 of
      TyArr tArg tRes
        | tArg == typeOf te2 -> pure (TxprApp tRes te1 te2)
        | otherwise -> failwith (ETypeMismatch tArg (typeOf te2))
      _ -> failwith (ENotAFunction (typeOf te1))

  ExprIf cond eThen eElse -> do
    teCond <- typing cond
    teThen <- typing eThen
    teElse <- typing eElse
    let
      t1 = typeOf teCond
      t2 = typeOf teThen
      t3 = typeOf teElse
    case t1 of
      TyBool -> do
        when (t2 /= t3) do
          failwith (ETypeMismatch t2 t3)
        pure (TxprIf t2 teCond teThen teElse)
      _ -> failwith (ETypeMismatch TyBool t1)

  ExprLet v e1 e2 -> do
    te1 <- typing e1
    whenM (isJust <$> (lookup v)) do
      warn (WShadowing v)
    te2 <- withExtends [ v /\ typeOf te1 ] (typing e2)
    pure (TxprLet (typeOf te2) v (typeOf te1) te1 te2)

  ExprPrim prim args ->
    let
      { typ: tPrim, args: tArgs } = typeofPrim prim
    in
      case zipMaybe tArgs args of
        Nothing -> failwith EPrimArityMismatch
        Just ts -> do
          typedArgs <- traverseArr (uncurry match) ts
          pure (TxprPrim tPrim prim typedArgs)
        _ -> failwith (EOtherError "Not implemented")

  -- Type abstraction Λα. e  (System F's `λα:*. e`): bind the type variable α (kind *)
  -- in the context, type the body, and quantify the result type over α.
  --
  --   Γ, α ⊢ e : T
  --   ----------------------
  --   Γ ⊢ Λα. e : Πα. T
  ExprTyAbs v e -> do
    te <- withExtendTy v (typing e)
    pure (TxprTyAbs (TyPi v (typeOf te)) v te)

  -- Type application e [A]: e must be polymorphic (a Πα. B); the result is B with α
  -- substituted by A.
  --
  --   Γ ⊢ e : Πα. B
  --   ----------------------
  --   Γ ⊢ e [A] : B[A/α]
  ExprTyApp e tArg -> do
    te <- typing e
    case typeOf te of
      TyPi v tBody -> do
        tRes <- liftEither (typeSubst v tArg tBody)
        pure (TxprTyApp tRes te tArg)
      _ -> failwith (EInvalidTypeApp (typeOf te))

  where
  withExtends :: Array (Var /\ Type_) -> TypingM ~> TypingM
  withExtends bindings = local (extendAll bindings)

  extendAll :: Array (Var /\ Type_) -> TypeEnv -> TypeEnv
  extendAll bindings env = foldl (\e (v /\ t) -> extend v t e) env bindings

  -- bind a *type* variable (kind *) for the scope of a type abstraction's body
  withExtendTy :: Var -> TypingM ~> TypingM
  withExtendTy v = local (TETyVar v)

  liftEither :: forall a. Either TypeError a -> TypingM a
  liftEither = case _ of
    Left err -> failwith err
    Right a -> pure a

  -- a manual monadic traverse over an array (avoids the `Data.Traversable.traverseArrayImpl`
  -- foreign, whose native runtime support is deferred)
  traverseArr :: forall a b. (a -> TypingM b) -> Array a -> TypingM (Array b)
  traverseArr f xs = case uncons xs of
    Nothing -> pure []
    Just { head, tail } -> do
      b <- f head
      bs <- traverseArr f tail
      pure (Array.cons b bs)

  match :: Type_ -> Expr -> _ TypedExpr
  match tExpect exp = do
    txp <- typing exp
    if typeOf txp == tExpect then pure txp
    else failwith (ETypeMismatch tExpect (typeOf txp))

  zipMaybe :: forall a b. Array a -> Array b -> Maybe (Array (a /\ b))
  zipMaybe = go []
    where
    go acc xs ys = case uncons xs, uncons ys of
      Just { head: x, tail: xs' }, Just { head: y, tail: ys' } -> go (Array.cons (x /\ y) acc) xs' ys'
      -- both exhausted together ⇒ equal length ⇒ success (restore original order)
      Nothing, Nothing -> Just (Array.reverse acc)
      -- one ran out before the other ⇒ length mismatch
      _, _ -> Nothing

typeofPrim :: Primitive -> { typ :: Type_, args :: Array Type_ }
typeofPrim = case _ of
  PrimAdd -> { typ: TyInt, args: [ TyInt, TyInt ] }
  PrimSub -> { typ: TyInt, args: [ TyInt, TyInt ] }
  PrimMul -> { typ: TyInt, args: [ TyInt, TyInt ] }
  PrimIsZero -> { typ: TyBool, args: [ TyInt ] }
  PrimEqInt -> { typ: TyBool, args: [ TyInt, TyInt ] }
  PrimCompInt -> { typ: TyInt, args: [ TyInt, TyInt ] }

typecheck :: Expr -> Either TypeError TypedExpr
typecheck e = typing e # runTyping emptyEnv { nextMeta: 0, warnings: [] }