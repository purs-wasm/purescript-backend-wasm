-- | Free-variable analysis over the middle IR (`MiddleEnd.IR`), used by MIR
-- | optimization passes (e.g. lambda lifting's capture computation) and by the
-- | backend lowering's closure conversion (`Lower` imports `freeVars`). A
-- | self-contained, pure analysis over the uncurried MIR, where a lambda binds a
-- | parameter *list* and an application takes an argument *list*.
module PureScript.Backend.Wasm.MiddleEnd.FreeVars
  ( freeVars
  , binderVars
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Qualified(..))

-- | The free *local* variables of an expression: identifiers referenced via
-- | `Qualified Nothing` not bound by an enclosing lambda, `let`, or case binder.
-- | Order is first-appearance, deduplicated — it indexes a closure's captures, so
-- | it must be deterministic.
-- |
-- | Computed as the *scope-independent* free set (`rawFreeVars`) minus the given
-- | `bound` — splitting out the bound-independent part keeps the result identical for
-- | every caller of a node regardless of their `bound`.
freeVars :: Array String -> M.Expr -> Array String
freeVars bound = case Array.null bound of
  true -> rawFreeVars
  false ->
    let
      boundSet = Set.fromFoldable bound
    in
      Array.filter (\x -> not (Set.member x boundSet)) <<< rawFreeVars

-- | The free variables of an expression with *nothing* externally bound, in
-- | first-appearance order with duplicates removed at every node (so the result is
-- | small and the global first-appearance order is preserved).
rawFreeVars :: M.Expr -> Array String
rawFreeVars = go
  where
  dedup = Array.nub
  go = case _ of
    M.Var (Qualified Nothing x) -> [ x ]
    M.Var _ -> []
    M.Lit lit -> goLit lit
    M.Constructor _ _ _ -> []
    M.Accessor _ e -> rawFreeVars e
    M.Update e _ updates -> dedup (rawFreeVars e <> (updates >>= \(Tuple _ v) -> rawFreeVars v))
    M.Abs params e -> Array.filter (\x -> not (Array.elem x params)) (rawFreeVars e)
    M.App head args -> dedup (rawFreeVars head <> (args >>= rawFreeVars))
    M.Perform e -> rawFreeVars e
    M.Case scruts alts -> dedup ((scruts >>= rawFreeVars) <> (alts >>= goAlt))
    M.Let binds body ->
      -- Conservative scoping: every let-bound name is in scope for both the
      -- right-hand sides and the body (exact for recursive `let`, a safe
      -- over-approximation otherwise).
      let
        names = binds >>= bindNames
      in
        Array.filter (\x -> not (Array.elem x names))
          (dedup ((binds >>= bindExprs >>= rawFreeVars) <> rawFreeVars body))
  goLit = case _ of
    LitArray es -> dedup (es >>= rawFreeVars)
    LitObject kvs -> dedup (kvs >>= \(Tuple _ v) -> rawFreeVars v)
    _ -> []
  goAlt alt =
    let
      names = alt.binders >>= binderVars
    in
      Array.filter (\x -> not (Array.elem x names))
        ( case alt.result of
            Right e -> rawFreeVars e
            Left guards -> dedup (guards >>= \g -> rawFreeVars g.guard <> rawFreeVars g.expression)
        )
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
