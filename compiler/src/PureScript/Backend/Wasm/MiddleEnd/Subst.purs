-- | Capture-avoiding substitution over the MIR (`PureScript.Backend.Wasm.MiddleEnd.IR`),
-- | shared by the middle-end optimizer (lambda lifting) and by lowering (legalizing a
-- | recursive-value `let` into the `newWithSelf` knot-tie). A shared `MiddleEnd` utility,
-- | like `FreeVars`, so `Lower` need not reach into an `Optimize`-internal module.
module PureScript.Backend.Wasm.MiddleEnd.Subst
  ( substMany
  , mkApp
  , boundNames
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (binderVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Literal(..), Qualified(..))

-- | Replace free occurrences of each substituted local with its replacement, in a
-- | *single* traversal, stopping at any binder that rebinds the name (capture
-- | avoidance) by dropping it from the scope's map. Each replacement only references
-- | already-in-scope names, so no freshening is needed — and the replacements never
-- | introduce another substituted name (the lifted idents are excluded from the
-- | captured frees), so applying them all at once equals folding them one at a time.
-- | A per-substitution fold instead re-walked the expression once per lifted group,
-- | i.e. O(groups × size) on a `let`/`where` with many recursive functions.
substMany :: Map String M.Expr -> M.Expr -> M.Expr
substMany = go
  where
  go subs e
    | Map.isEmpty subs = e
    | otherwise = case e of
        M.Var (Qualified Nothing n) -> case Map.lookup n subs of
          Just r -> r
          Nothing -> e
        M.Var _ -> e
        M.Lit lit -> M.Lit (goLit subs lit)
        M.Constructor _ _ _ -> e
        M.Accessor l x -> M.Accessor l (go subs x)
        M.Update x cf kvs -> M.Update (go subs x) cf (map (map (go subs)) kvs)
        M.Abs ps b ->
          let
            subs' = dropNames ps subs
          in
            if Map.isEmpty subs' then e else M.Abs ps (go subs' b)
        -- a substituted head may itself be an application; keep `App` flat
        M.App f a -> mkApp (go subs f) (map (go subs) a)
        M.Perform x -> M.Perform (go subs x)
        M.Case ss alts -> M.Case (map (go subs) ss) (map (goAlt subs) alts)
        M.Let binds body ->
          let
            subs' = dropNames (binds >>= boundNames) subs
          in
            if Map.isEmpty subs' then e
            else M.Let (map (goBind subs') binds) (go subs' body)
  goLit subs = case _ of
    LitArray es -> LitArray (map (go subs) es)
    LitObject kvs -> LitObject (map (map (go subs)) kvs)
    other -> other
  goAlt subs alt =
    let
      subs' = dropNames (alt.binders >>= binderVars) subs
    in
      if Map.isEmpty subs' then alt else alt { result = goResult subs' alt.result }
  goResult subs = case _ of
    Right e -> Right (go subs e)
    Left gs -> Left (map (\g -> { guard: go subs g.guard, expression: go subs g.expression }) gs)
  goBind subs = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go subs e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go subs r.expr }) rs)
  dropNames names subs = foldl (flip Map.delete) subs names

-- | Smart application that preserves the MIR invariant that an `App` head is never
-- | itself an `App`: applying to an existing application extends its argument list.
mkApp :: M.Expr -> Array M.Expr -> M.Expr
mkApp head args
  | Array.null args = head
  | otherwise = case head of
      M.App h0 args0 -> M.App h0 (args0 <> args)
      _ -> M.App head args

boundNames :: M.Bind -> Array String
boundNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs
