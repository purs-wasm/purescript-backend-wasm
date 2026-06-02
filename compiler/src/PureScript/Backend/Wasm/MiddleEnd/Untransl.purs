-- | Translate the middle IR (`MiddleEnd.IR`) back to CoreFn — the inverse of
-- | `MiddleEnd.Transl`. This exists so the optimization layer can be wired into the
-- | pipeline behind the existing CoreFn lowering (ADR 0005): a module's bindings go
-- | CoreFn → MIR → (optimize) → CoreFn, and with no optimization passes yet the
-- | round trip is the identity (modulo source spans, which the backend ignores).
-- | Uncurrying is undone here — a parameter list re-nests into curried `Abs`, an
-- | argument list back into a left-nested `App` spine; dropped spans are filled with
-- | a zero span and the kept binding `Meta` is restored.
module PureScript.Backend.Wasm.MiddleEnd.Untransl
  ( untranslBind
  , untranslExpr
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn as C

untranslBind :: M.Bind -> C.Bind
untranslBind = case _ of
  M.NonRec meta ident e -> C.NonRec (ann meta) ident (untranslExpr e)
  M.Rec rs -> C.Rec (map (\r -> { ann: ann r.meta, ident: r.ident, expr: untranslExpr r.expr }) rs)

untranslExpr :: M.Expr -> C.Expr
untranslExpr = case _ of
  M.Lit lit -> C.Literal noAnn (untranslLit lit)
  M.Var q -> C.Var noAnn q
  M.Constructor typeName ctorName fields -> C.Constructor noAnn typeName ctorName fields
  M.Accessor label e -> C.Accessor noAnn label (untranslExpr e)
  M.Update e copyFields updates -> C.ObjectUpdate noAnn (untranslExpr e) copyFields (map (map untranslExpr) updates)
  -- re-nest a parameter list into curried lambdas
  M.Abs params body -> foldr (\p acc -> C.Abs noAnn p acc) (untranslExpr body) params
  -- re-nest an argument list into a left-associated application spine
  M.App head args -> foldl (\acc a -> C.App noAnn acc a) (untranslExpr head) (map untranslExpr args)
  M.Case scrutinees alternatives -> C.Case noAnn (map untranslExpr scrutinees) (map untranslAlt alternatives)
  M.Let binds body -> C.Let noAnn (map untranslBind binds) (untranslExpr body)

untranslLit :: C.Literal M.Expr -> C.Literal C.Expr
untranslLit = case _ of
  C.LitInt n -> C.LitInt n
  C.LitNumber n -> C.LitNumber n
  C.LitString s -> C.LitString s
  C.LitChar c -> C.LitChar c
  C.LitBoolean b -> C.LitBoolean b
  C.LitArray es -> C.LitArray (map untranslExpr es)
  C.LitObject kvs -> C.LitObject (map (map untranslExpr) kvs)

untranslAlt :: M.Alt -> C.CaseAlternative
untranslAlt alt = { binders: alt.binders, result: untranslResult alt.result }
  where
  untranslResult = case _ of
    Right e -> Right (untranslExpr e)
    Left guards -> Left (map (\g -> { guard: untranslExpr g.guard, expression: untranslExpr g.expression }) guards)

ann :: Maybe C.Meta -> C.Ann
ann meta = { span: zeroSpan, meta }

noAnn :: C.Ann
noAnn = ann Nothing

zeroSpan :: C.SourceSpan
zeroSpan = { start: zeroPos, end: zeroPos }
  where
  zeroPos = { line: 0, column: 0 }
