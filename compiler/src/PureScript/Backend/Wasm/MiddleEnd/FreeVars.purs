-- | Free-variable analysis over the middle IR (`MiddleEnd.IR`), used by MIR
-- | optimization passes (e.g. lambda lifting's capture computation). A
-- | self-contained, pure analysis. Mirrors `Lower.FreeVars` but on the uncurried
-- | MIR, where a lambda binds a parameter *list* and an application takes an
-- | argument *list*.
module PureScript.Backend.Wasm.MiddleEnd.FreeVars
  ( freeVars
  , binderVars
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Qualified(..))

-- | The free *local* variables of an expression: identifiers referenced via
-- | `Qualified Nothing` not bound by an enclosing lambda, `let`, or case binder.
-- | Order is first-appearance, deduplicated — it indexes a closure's captures, so
-- | it must be deterministic.
freeVars :: Array String -> M.Expr -> Array String
freeVars bound = Array.nub <<< goExpr bound
  where
  goExpr bnd = case _ of
    M.Var (Qualified Nothing x) -> if Array.elem x bnd then [] else [ x ]
    M.Var _ -> []
    M.Lit lit -> goLit bnd lit
    M.Constructor _ _ _ -> []
    M.Accessor _ e -> goExpr bnd e
    M.Update e _ updates -> goExpr bnd e <> (updates >>= \(Tuple _ v) -> goExpr bnd v)
    M.Abs params e -> goExpr (bnd <> params) e
    M.App head args -> goExpr bnd head <> (args >>= goExpr bnd)
    M.Perform e -> goExpr bnd e
    M.Case scruts alts -> (scruts >>= goExpr bnd) <> (alts >>= goAlt bnd)
    M.Let binds body ->
      -- Conservative scoping: every let-bound name is in scope for both the
      -- right-hand sides and the body (exact for recursive `let`, a safe
      -- over-approximation otherwise).
      let
        bnd' = bnd <> (binds >>= bindNames)
      in
        (binds >>= bindExprs >>= goExpr bnd') <> goExpr bnd' body
  goLit bnd = case _ of
    LitArray es -> es >>= goExpr bnd
    LitObject kvs -> kvs >>= \(Tuple _ v) -> goExpr bnd v
    _ -> []
  goAlt bnd alt =
    let
      bnd' = bnd <> (alt.binders >>= binderVars)
    in
      case alt.result of
        Right e -> goExpr bnd' e
        Left guards -> guards >>= \g -> goExpr bnd' g.guard <> goExpr bnd' g.expression
  bindNames = case _ of
    M.NonRec _ n _ -> [ n ]
    M.Rec rs -> map _.ident rs
  bindExprs = case _ of
    M.NonRec _ _ e -> [ e ]
    M.Rec rs -> map _.expr rs

-- | The variables a binder brings into scope.
binderVars :: Binder -> Array String
binderVars = case _ of
  NullBinder _ -> []
  VarBinder _ n -> [ n ]
  NamedBinder _ n b -> Array.cons n (binderVars b)
  LiteralBinder _ lit -> litBinderVars lit
  ConstructorBinder _ _ _ bs -> bs >>= binderVars
  where
  litBinderVars = case _ of
    LitArray bs -> bs >>= binderVars
    LitObject kvs -> kvs >>= \(Tuple _ b) -> binderVars b
    _ -> []
