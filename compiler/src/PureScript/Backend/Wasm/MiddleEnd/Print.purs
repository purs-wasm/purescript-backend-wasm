-- | A readable, source-like printer for the middle IR (`MiddleEnd.IR`), for
-- | eyeballing how `Optimize` passes rewrite the MIR (the derived `Show` is too
-- | noisy for that). Uncurried application is rendered call-style — `f(a, b)` — so
-- | the arity is visible; dictionary / newtype binding meta is tagged.
module PureScript.Backend.Wasm.MiddleEnd.Print
  ( printModule
  , printBind
  , printExpr
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Meta(..), Qualified(..))

printModule :: M.Module -> String
printModule m =
  "module " <> joinWith "." m.name <> " where\n\n"
    <> joinWith "\n\n" (map (printBind 0) m.decls)

printBind :: Int -> M.Bind -> String
printBind ind = case _ of
  M.NonRec meta ident e -> metaTag meta <> ident <> " = " <> printExpr ind e
  M.Rec rs ->
    "rec\n" <> joinWith "\n"
      (map (\r -> pad (ind + 1) <> metaTag r.meta <> r.ident <> " = " <> printExpr (ind + 1) r.expr) rs)

printExpr :: Int -> M.Expr -> String
printExpr ind = case _ of
  M.Lit lit -> printLit ind lit
  M.Var q -> printQualified q
  M.Constructor _ ctorName fields -> "«ctor " <> ctorName <> "/" <> show (Array.length fields) <> "»"
  M.Accessor label e -> atom ind e <> "." <> label
  M.Update e _ updates ->
    atom ind e <> " { " <> joinWith ", " (map (\(Tuple l v) -> l <> " = " <> printExpr ind v) updates) <> " }"
  M.Abs params body -> "\\" <> joinWith " " params <> " -> " <> printExpr ind body
  M.App head args -> atom ind head <> "(" <> joinWith ", " (map (printExpr ind) args) <> ")"
  M.Case scrutinees alternatives ->
    "case " <> joinWith ", " (map (atom ind) scrutinees) <> " of\n"
      <> joinWith "\n" (map (printAlt (ind + 1)) alternatives)
  M.Let binds body ->
    "let\n"
      <> joinWith "\n" (map (\b -> pad (ind + 1) <> printBind (ind + 1) b) binds)
      <> "\n"
      <> pad ind
      <> "in "
      <> printExpr ind body

-- | Parenthesise a non-atomic expression used in head / scrutinee / accessor
-- | position, so `(\x -> …)(y)` and `(let … in …).l` read unambiguously.
atom :: Int -> M.Expr -> String
atom ind e = case e of
  M.Lit _ -> printExpr ind e
  M.Var _ -> printExpr ind e
  M.Constructor _ _ _ -> printExpr ind e
  M.Accessor _ _ -> printExpr ind e
  M.App _ _ -> printExpr ind e
  _ -> "(" <> printExpr ind e <> ")"

printAlt :: Int -> M.Alt -> String
printAlt ind alt =
  pad ind <> joinWith ", " (map printBinder alt.binders) <> case alt.result of
    Right e -> " -> " <> printExpr ind e
    Left guards ->
      joinWith "" (map (\g -> "\n" <> pad (ind + 1) <> "| " <> printExpr ind g.guard <> " -> " <> printExpr ind g.expression) guards)

printLit :: Int -> Literal M.Expr -> String
printLit ind = case _ of
  LitInt n -> show n
  LitNumber n -> show n
  LitString s -> show s
  LitChar c -> show c
  LitBoolean b -> if b then "true" else "false"
  LitArray es -> "[" <> joinWith ", " (map (printExpr ind) es) <> "]"
  LitObject kvs -> "{ " <> joinWith ", " (map (\(Tuple k v) -> k <> ": " <> printExpr ind v) kvs) <> " }"

printBinder :: Binder -> String
printBinder = case _ of
  NullBinder _ -> "_"
  VarBinder _ n -> n
  NamedBinder _ n b -> n <> "@" <> printBinder b
  ConstructorBinder _ _ ctor subs ->
    printQualified ctor <> if Array.null subs then "" else "(" <> joinWith ", " (map printBinder subs) <> ")"
  LiteralBinder _ lit -> case lit of
    LitInt n -> show n
    LitNumber n -> show n
    LitString s -> show s
    LitChar c -> show c
    LitBoolean b -> if b then "true" else "false"
    LitArray bs -> "[" <> joinWith ", " (map printBinder bs) <> "]"
    LitObject kvs -> "{ " <> joinWith ", " (map (\(Tuple k b) -> k <> ": " <> printBinder b) kvs) <> " }"

printQualified :: Qualified String -> String
printQualified (Qualified mModule name) = case mModule of
  Just m -> joinWith "." m <> "." <> name
  Nothing -> name

-- | A short tag for the binding meta a reader cares about (the constructors that
-- | dictionary elimination targets); other meta is not shown.
metaTag :: Maybe Meta -> String
metaTag = case _ of
  Just IsTypeClassConstructor -> "{dict} "
  Just IsNewtype -> "{newtype} "
  _ -> ""

pad :: Int -> String
pad n = joinWith "" (Array.replicate n "  ")
