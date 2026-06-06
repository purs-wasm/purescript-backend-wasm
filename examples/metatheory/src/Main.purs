module Examples.Metatheory.Main where

import Prelude

import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Examples.Metatheory.Eval (EvalResult(..), NormalForm, step)
import Examples.Metatheory.Print (printNormalForm, printType, printTypeError)
import Examples.Metatheory.Primitive (Primitive(..))
import Examples.Metatheory.Syntax (Constant(..), Expr(..), Type_(..), Var(..))
import Examples.Metatheory.Syntax.Parser (parseProgram)
import Examples.Metatheory.Typecheck (TypedExpr, typeOf)
import Examples.Metatheory.Typecheck as TC

-- we leave frontend (parsing) as an open hole.
eval :: Expr -> Either String { val :: NormalForm, typ :: Type_ }
eval = typecheck >=> steps
  where
  typecheck = TC.typecheck >>> lmap printTypeError

  steps txp = case step txp of
    EvalDone nf -> pure nf
    EvalStep txp' -> steps txp'
    EvalStuck -> Left "Eval stuck."

-- | Typecheck and evaluate a term, reporting both as pretty-printed strings. `typ` and
-- | `val` are computed independently, so a well-typed term whose evaluation is not yet
-- | supported still reports its type (with `val` = `<stuck>`). The record has only
-- | `String` fields, so it crosses to JS as `{ typ, val }` (ADR 0024).
report :: Expr -> { typ :: String, val :: String }
report e = case TC.typecheck e of
  Left err -> { typ: printTypeError err, val: "" }
  Right txp -> { typ: printType (typeOf txp), val: evalToString txp }
  where
  evalToString :: TypedExpr -> String
  evalToString = go
    where
    go t = case step t of
      EvalDone nf -> printNormalForm nf.val
      EvalStep t' -> go t'
      EvalStuck -> "<stuck>"

-- | The JS-safe entry point: parse a source string, then typecheck and evaluate it,
-- | returning `{ typ, val }` (both `String`, so the record crosses to JS — ADR 0024).
-- | A parse failure is reported in `typ` with `val` empty.
run :: String -> { typ :: String, val :: String }
run src = case parseProgram src of
  Left err -> { typ: err, val: "" }
  Right e -> report e

-- | A JS-safe entry that selects a built-in sample term by index (handy before a
-- | source string is available).
runSample :: Int -> { typ :: String, val :: String }
runSample = report <<< sample

sample :: Int -> Expr
sample = case _ of
  -- id [Int] 5         : typechecks to `int`; eval is stuck (no type-app reduction yet)
  0 -> ExprApp (ExprTyApp idE TyInt) (ExprLit (CstInt 5))
  -- (λx:int. x + 1) 41 : type-checks (`int`) and evaluates (`42`)
  1 -> ExprApp (ExprAbs x TyInt (ExprPrim PrimAdd [ ExprVar x, ExprLit (CstInt 1) ])) (ExprLit (CstInt 41))
  -- (λx:int. x * x) 7  : evaluates to `49`
  2 -> ExprApp (ExprAbs x TyInt (ExprPrim PrimMul [ ExprVar x, ExprVar x ])) (ExprLit (CstInt 7))
  -- (λx:int. x) true   : a type error (int expected, bool given)
  3 -> ExprApp (ExprAbs x TyInt (ExprVar x)) (ExprLit (CstBool true))
  _ -> ExprLit (CstInt 0)
  where
  x = Var "x"
  -- id = Λα. λx:α. x
  idE = ExprTyAbs (Var "α") (ExprAbs x (TyVar (Var "α")) (ExprVar x))
