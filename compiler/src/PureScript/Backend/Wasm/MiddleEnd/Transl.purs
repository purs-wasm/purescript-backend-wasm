-- | Translate CoreFn to the middle IR (`MiddleEnd.IR`). This is the **faithful,
-- | mechanical** front of the pipeline (ADR 0005): no optimization happens here.
-- | The only structural change is **uncurrying** — consecutive `C.Abs` collapse
-- | into one parameter list and a curried `C.App` spine into one argument list, so
-- | the MIR carries arity explicitly. Everything else maps one-to-one (dictionaries
-- | and records stay ordinary values; source spans are dropped, the `Meta` a later
-- | pass needs is kept on bindings).
module PureScript.Backend.Wasm.MiddleEnd.Transl
  ( translModule
  , translBind
  , translExpr
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn as C

translModule :: C.Module -> M.Module
translModule m = { name: m.name, decls: map translBind m.decls }

translBind :: C.Bind -> M.Bind
translBind = case _ of
  C.NonRec ann ident e -> M.NonRec ann.meta ident (translExpr e)
  C.Rec rs -> M.Rec (map (\r -> { meta: r.ann.meta, ident: r.ident, expr: translExpr r.expr }) rs)

translExpr :: C.Expr -> M.Expr
translExpr expr = case expr of
  C.Literal _ lit -> M.Lit (translLit lit)
  C.Var _ q -> M.Var q
  C.Constructor _ typeName ctorName fields -> M.Constructor typeName ctorName fields
  C.Accessor _ label e -> M.Accessor label (translExpr e)
  C.ObjectUpdate _ e copyFields updates -> M.Update (translExpr e) copyFields (map (map translExpr) updates)
  -- collapse a curried lambda into one parameter list
  C.Abs _ _ _ -> let peeled = peelAbs expr in M.Abs peeled.params (translExpr peeled.body)
  -- collapse a curried application spine into one argument list
  C.App _ _ _ -> let spine = collectApp expr in M.App (translExpr spine.head) (map translExpr spine.args)
  C.Case _ scrutinees alternatives -> M.Case (map translExpr scrutinees) (map translAlt alternatives)
  C.Let _ binds body -> M.Let (map translBind binds) (translExpr body)

translLit :: C.Literal C.Expr -> C.Literal M.Expr
translLit = case _ of
  C.LitInt n -> C.LitInt n
  C.LitNumber n -> C.LitNumber n
  C.LitString s -> C.LitString s
  C.LitChar c -> C.LitChar c
  C.LitBoolean b -> C.LitBoolean b
  C.LitArray es -> C.LitArray (map translExpr es)
  C.LitObject kvs -> C.LitObject (map (map translExpr) kvs)

translAlt :: C.CaseAlternative -> M.Alt
translAlt alt = { binders: alt.binders, result: translResult alt.result }
  where
  translResult = case _ of
    Right e -> Right (translExpr e)
    Left guards -> Left (map (\g -> { guard: translExpr g.guard, expression: translExpr g.expression }) guards)

-- | Peel a curried lambda into its parameter idents (outermost first) and body.
peelAbs :: C.Expr -> { params :: Array C.Ident, body :: C.Expr }
peelAbs = go []
  where
  go acc = case _ of
    C.Abs _ p b -> go (Array.snoc acc p) b
    body -> { params: acc, body }

-- | Flatten a curried application spine: `App (App f a) b` → `f` with `[a, b]`.
collectApp :: C.Expr -> { head :: C.Expr, args :: Array C.Expr }
collectApp = go []
  where
  go acc = case _ of
    C.App _ f a -> go (Array.cons a acc) f
    other -> { head: other, args: acc }
