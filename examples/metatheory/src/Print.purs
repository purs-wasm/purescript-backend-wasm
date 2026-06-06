module Examples.Metatheory.Print where

import Prelude

import Examples.Metatheory.Eval (NormalForm(..))
import Examples.Metatheory.Syntax (Type_(..), Var(..))
import Examples.Metatheory.Typecheck (TypeError(..))
import Fmt as Fmt

printType :: Type_ -> String
printType = printWithPrec 0
  where
  printWithPrec p = case _ of
    TyInt -> "int"
    TyBool -> "bool"
    TyVar (Var var) -> var
    TyArr t1 t2 -> parens (p > 0) $ Fmt.fmt @"{t1} -> {t2}" { t1: printWithPrec (p + 1) t1, t2: printWithPrec p t2 }
    TyPi (Var v) t -> parens (p > 1) $ Fmt.fmt @"∀ {v}. {t}" { v, t: printWithPrec p t }

printNormalForm :: NormalForm -> String
printNormalForm = case _ of
  NFBool b -> show b
  NFInt i -> show i
  NFAbs _ _ _ -> "<fun>"
  NFTyAbs _ _ -> "<polyfun>"

parens :: Boolean -> String -> String
parens true s = "(" <> s <> ")"
parens _ s = s

printTypeError :: TypeError -> String
printTypeError = case _ of
  WShadowing (Var v) -> Fmt.fmt @"[WARN] {v} is shadowed" { v }
  ETypeMismatch exp fnd -> Fmt.fmt
    @"[ERROR] Types do not match. \n\
    \ Expect: {expect}\n\
    \ Found : {found}"
    { expect: printType exp
    , found: printType fnd
    }
  ENotAFunction t -> Fmt.fmt @"[ERROR] Not a function: a value of type {t} cannot be applied" { t: printType t }
  ENotAType t -> Fmt.fmt @"[ERROR] Not a type: {t}" { t: printType t }
  EUnboundVariable (Var v) -> Fmt.fmt @"[ERROR] Unbound variable: {v}" { v }
  EUnboundTypeVariable (Var v) -> Fmt.fmt @"[ERROR] Unbound type variable: {v}" { v }
  EUnexpectedForall -> "[ERROR] Unexpected polymorphic type (∀) where a monomorphic type was required"
  EPrimArityMismatch -> "[ERROR] A primitive operator was applied to the wrong number of arguments"
  EInvalidTypeApp t -> Fmt.fmt @"[ERROR] Type application to a non-polymorphic value of type {t}" { t: printType t }
  EOtherError msg -> Fmt.fmt @"[ERROR] {msg}" { msg }
