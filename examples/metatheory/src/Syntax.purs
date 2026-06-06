module Examples.Metatheory.Syntax where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Examples.Metatheory.Primitive (Primitive)
import Fmt as Fmt

newtype Var = Var String

derive newtype instance Eq Var
derive newtype instance Ord Var
instance Show Var where
  show (Var s) = Fmt.fmt @"(Var {s})" { s }

data Type_
  = TyInt
  | TyBool
  | TyVar Var
  | TyArr Type_ Type_ -- Function type
  -- second orderd machinery
  | TyPi Var Type_ -- Π-type is a type abstraction, which in tunrns 

derive instance Generic Type_ _
derive instance Eq Type_
instance Show Type_ where
  show it = genericShow it

data Constant
  = CstInt Int
  | CstBool Boolean

derive instance Generic Constant _
derive instance Eq Constant
instance Show Constant where
  show = genericShow

data Expr
  = ExprLit Constant
  | ExprVar Var
  | ExprPrim Primitive (Array Expr)
  | ExprAbs Var Type_ Expr
  | ExprApp Expr Expr
  | ExprIf Expr Expr Expr
  | ExprLet Var Expr Expr
  | ExprTyAbs Var Expr -- 2nd-order abstraction (a.k.a. polymorphinc function)
  | ExprTyApp Expr Type_

-- | ExprLetrec Var Expr Expr

derive instance Generic Expr _
derive instance Eq Expr
instance Show Expr where
  show e = genericShow e