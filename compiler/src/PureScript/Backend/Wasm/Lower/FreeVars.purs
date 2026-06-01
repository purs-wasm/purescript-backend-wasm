-- | Free-variable analysis over CoreFn, used by the lowering's closure
-- | conversion to decide what each lambda must capture. A self-contained, pure
-- | analysis, kept separate from the lowering algorithm.
module PureScript.Backend.Wasm.Lower.FreeVars
  ( freeVars
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import PureScript.CoreFn (Bind(..), Qualified(..))
import PureScript.CoreFn as C

-- | The free *local* variables of an expression: identifiers referenced via
-- | `Qualified Nothing` that are not bound by an enclosing lambda, `let`, or
-- | case binder. Qualified names (top-level / foreign / constructors) are never
-- | captured. Order is first-appearance, deduplicated — used both to build a
-- | closure's capture list and to index its `EnvField`s, so it must be
-- | deterministic.
freeVars :: Array String -> C.Expr -> Array String
freeVars bound = Array.nub <<< goExpr bound
  where
  goExpr bnd = case _ of
    C.Var _ (Qualified Nothing x) -> if Array.elem x bnd then [] else [ x ]
    C.Var _ _ -> []
    C.Literal _ lit -> goLit bnd lit
    C.Constructor _ _ _ _ -> []
    C.Accessor _ _ e -> goExpr bnd e
    C.ObjectUpdate _ e _ updates -> goExpr bnd e <> (updates >>= \(Tuple _ v) -> goExpr bnd v)
    C.Abs _ p e -> goExpr (Array.snoc bnd p) e
    C.App _ f a -> goExpr bnd f <> goExpr bnd a
    C.Case _ scruts alts -> (scruts >>= goExpr bnd) <> (alts >>= goAlt bnd)
    C.Let _ binds body ->
      -- Conservative scoping: every let-bound name is treated as in scope for both
      -- the right-hand sides and the body. Exact for recursive `let`; for a
      -- non-recursive `let` it over-approximates the scope, which is safe unless a
      -- right-hand side refers to an outer variable shadowed by a let-bound name.
      let
        bnd' = bnd <> (binds >>= bindNames)
      in
        (binds >>= bindExprs >>= goExpr bnd') <> goExpr bnd' body
  goLit bnd = case _ of
    C.LitArray es -> es >>= goExpr bnd
    C.LitObject kvs -> kvs >>= \(Tuple _ v) -> goExpr bnd v
    _ -> []
  goAlt bnd alt =
    let
      bnd' = bnd <> (alt.binders >>= binderVars)
    in
      case alt.result of
        Right e -> goExpr bnd' e
        Left guards -> guards >>= \g -> goExpr bnd' g.guard <> goExpr bnd' g.expression
  bindNames = case _ of
    NonRec _ n _ -> [ n ]
    Rec rs -> map _.ident rs
  bindExprs = case _ of
    NonRec _ _ e -> [ e ]
    Rec rs -> map _.expr rs

-- | The variables a binder brings into scope.
binderVars :: C.Binder -> Array String
binderVars = case _ of
  C.NullBinder _ -> []
  C.VarBinder _ n -> [ n ]
  C.NamedBinder _ n b -> Array.cons n (binderVars b)
  C.LiteralBinder _ lit -> litBinderVars lit
  C.ConstructorBinder _ _ _ bs -> bs >>= binderVars
  where
  litBinderVars = case _ of
    C.LitArray bs -> bs >>= binderVars
    C.LitObject kvs -> kvs >>= \(Tuple _ b) -> binderVars b
    _ -> []
