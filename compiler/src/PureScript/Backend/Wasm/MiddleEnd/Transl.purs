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
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn as C

translModule :: C.Module -> M.Module
translModule m = { name: m.name, decls: map translBind m.decls }

translBind :: C.Bind -> M.Bind
translBind = case _ of
  C.NonRec ann ident e -> M.NonRec (bindMeta ann.meta e) ident (translExpr e)
  C.Rec rs -> M.Rec (map (\r -> { meta: bindMeta r.ann.meta r.expr, ident: r.ident, expr: translExpr r.expr }) rs)

-- | The `Meta` to keep on a binding. A binding's own annotation carries it (e.g. a
-- | type-class dictionary constructor's `IsTypeClassConstructor`); but a user
-- | newtype constructor's `IsNewtype` sits on its *defining expression* (the
-- | identity `\x -> x`), not the binding, so promote that one onto the binding when
-- | the binding itself is unannotated — the simplifier needs it to treat the newtype
-- | as transparent (ADR 0015).
bindMeta :: Maybe C.Meta -> C.Expr -> Maybe C.Meta
bindMeta bind e = case bind of
  Just m -> Just m
  Nothing -> case exprMeta e of
    Just C.IsNewtype -> Just C.IsNewtype
    _ -> Nothing

-- | The `Meta` on an expression's own annotation (the first field of every node).
exprMeta :: C.Expr -> Maybe C.Meta
exprMeta = case _ of
  C.Literal a _ -> a.meta
  C.Var a _ -> a.meta
  C.Constructor a _ _ _ -> a.meta
  C.Accessor a _ _ -> a.meta
  C.ObjectUpdate a _ _ _ -> a.meta
  C.Abs a _ _ -> a.meta
  C.App a _ _ -> a.meta
  C.Case a _ _ -> a.meta
  C.Let a _ _ -> a.meta

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
