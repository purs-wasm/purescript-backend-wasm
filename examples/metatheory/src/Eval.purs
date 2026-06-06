module Examples.Metatheory.Eval where

import Prelude

import Data.Array (span, uncons)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Examples.Metatheory.Primitive (Primitive(..))
import Examples.Metatheory.Syntax (Constant(..), Type_(..), Var)
import Examples.Metatheory.Typecheck (TypedExpr(..), typeSubst)

data EvalResult a
  = EvalStep TypedExpr
  | EvalDone a
  | EvalStuck

data NormalForm
  = NFInt Int
  | NFBool Boolean
  | NFAbs Var Type_ TypedExpr -- a term abstraction λx:T. e
  | NFTyAbs Var TypedExpr -- a type abstraction Λα. e (a polymorphic value)

-- | Values: literals and both flavours of abstraction (System F's `Λα. e` is a value).
isNormalForm :: TypedExpr -> Boolean
isNormalForm = case _ of
  TxprLit _ _ -> true
  TxprAbs _ _ _ _ -> true
  TxprTyAbs _ _ _ -> true
  _ -> false

-- | One small step of call-by-value reduction (β for terms, β for types, `if`, `let`,
-- | and primitives), or `EvalDone` at a value, or `EvalStuck` on an irreducible non-value
-- | (which a well-typed term never reaches).
step :: TypedExpr -> EvalResult { val :: NormalForm, typ :: Type_ }
step = case _ of
  TxprLit typ (CstInt n) -> EvalDone { val: NFInt n, typ }
  TxprLit typ (CstBool b) -> EvalDone { val: NFBool b, typ }
  TxprAbs typ x t1 body -> EvalDone { val: NFAbs x t1 body, typ }
  TxprTyAbs typ a body -> EvalDone { val: NFTyAbs a body, typ }

  -- term application: reduce the function to a λ, then the argument, then β-substitute
  TxprApp typ e1 e2 -> case e1 of
    TxprAbs _ v _ body -> case step e2 of
      EvalStep e2' -> EvalStep (TxprApp typ e1 e2')
      EvalDone _ -> EvalStep (subst v e2 body)
      EvalStuck -> EvalStuck
    _ -> case step e1 of
      EvalStep e1' -> EvalStep (TxprApp typ e1' e2)
      _ -> EvalStuck

  -- type application: reduce to a Λ, then substitute the type argument into the body
  TxprTyApp typ e tArg -> case e of
    TxprTyAbs _ a body -> EvalStep (substTy a tArg body)
    _ -> case step e of
      EvalStep e' -> EvalStep (TxprTyApp typ e' tArg)
      _ -> EvalStuck

  -- conditional: reduce the scrutinee to a boolean literal, then pick the branch
  TxprIf typ cond th el -> case cond of
    TxprLit _ (CstBool true) -> EvalStep th
    TxprLit _ (CstBool false) -> EvalStep el
    _ -> case step cond of
      EvalStep cond' -> EvalStep (TxprIf typ cond' th el)
      _ -> EvalStuck

  -- let: substitute the bound term (call-by-name; the calculus is pure and terminating)
  TxprLet _ v _ e1 e2 -> EvalStep (subst v e1 e2)

  TxprPrim typ prim args -> do
    let { init: nfArgs, rest } = span isNormalForm args
    case uncons rest of
      Nothing -> evalPrim prim args
      Just { head: rdxArg, tail: rest' } -> do
        case step rdxArg of
          EvalStep rdxArg' -> EvalStep (TxprPrim typ prim (nfArgs <> [ rdxArg' ] <> rest'))
          EvalStuck -> EvalStuck
          EvalDone _ -> {- unreachable case -}  EvalStuck

  _ -> EvalStuck

  where
  evalPrim = case _, _ of
    PrimAdd, [ TxprLit _ (CstInt i1), (TxprLit _ (CstInt i2)) ] -> EvalStep $ TxprLit TyInt (CstInt (i1 + i2))
    PrimSub, [ TxprLit _ (CstInt i1), (TxprLit _ (CstInt i2)) ] -> EvalStep $ TxprLit TyInt (CstInt (i1 - i2))
    PrimMul, [ TxprLit _ (CstInt i1), (TxprLit _ (CstInt i2)) ] -> EvalStep $ TxprLit TyInt (CstInt (i1 * i2))
    PrimEqInt, [ TxprLit _ (CstInt i1), (TxprLit _ (CstInt i2)) ] -> EvalStep $ TxprLit TyBool (CstBool (i1 == i2))
    PrimCompInt, [ TxprLit _ (CstInt i1), (TxprLit _ (CstInt i2)) ] -> EvalStep $ TxprLit TyInt $ CstInt (compInt i1 i2)
    PrimIsZero, [ TxprLit _ (CstInt i) ] -> EvalStep $ TxprLit TyBool $ CstBool (i == 0)
    _, _ -> EvalStuck
    where
    compInt i1 i2 = case compare i1 i2 of
      EQ -> 0
      LT -> -1
      GT -> 1

  -- capture-avoiding-enough term substitution (binders that shadow `v` stop it)
  subst :: Var -> TypedExpr -> TypedExpr -> TypedExpr
  subst v e' e = case e of
    TxprLit _ _ -> e
    TxprVar _ x
      | x == v -> e'
      | otherwise -> e
    TxprAbs t v1 t1 body
      | v1 == v -> e -- shadowed: do not substitute under the inner binder
      | otherwise -> TxprAbs t v1 t1 (subst v e' body)
    TxprApp t e1 e2 -> TxprApp t (subst v e' e1) (subst v e' e2)
    TxprLet t n t1 e1 e2
      | n == v -> TxprLet t n t1 (subst v e' e1) e2
      | otherwise -> TxprLet t n t1 (subst v e' e1) (subst v e' e2)
    TxprIf t e1 e2 e3 -> TxprIf t (subst v e' e1) (subst v e' e2) (subst v e' e3)
    TxprPrim tprim prim args -> TxprPrim tprim prim ((subst v e') <$> args)
    -- a type-variable binder is a different namespace from the term variable `v`
    TxprTyAbs t a e1 -> TxprTyAbs t a (subst v e' e1)
    TxprTyApp t e1 t1 -> TxprTyApp t (subst v e' e1) t1

-- | Substitute the type variable `a` by `arg` throughout a term's type annotations
-- | (the reduct of `(Λα. e) [A]`). A nested `Λα. …` shadows the substitution.
substTy :: Var -> Type_ -> TypedExpr -> TypedExpr
substTy a arg = go
  where
  st = substType a arg
  go = case _ of
    TxprLit t c -> TxprLit (st t) c
    TxprVar t v -> TxprVar (st t) v
    TxprPrim t p as -> TxprPrim (st t) p (map go as)
    TxprAbs t v pt body -> TxprAbs (st t) v (st pt) (go body)
    TxprApp t f x -> TxprApp (st t) (go f) (go x)
    TxprIf t c d e -> TxprIf (st t) (go c) (go d) (go e)
    TxprLet t v pt e1 e2 -> TxprLet (st t) v (st pt) (go e1) (go e2)
    TxprTyAbs t a' body
      | a' == a -> TxprTyAbs (st t) a' body
      | otherwise -> TxprTyAbs (st t) a' (go body)
    TxprTyApp t f ta -> TxprTyApp (st t) (go f) (st ta)

-- type-into-type substitution (`typeSubst` never actually fails, so fall back to `t`)
substType :: Var -> Type_ -> Type_ -> Type_
substType a arg t = case typeSubst a arg t of
  Right t' -> t'
  Left _ -> t
