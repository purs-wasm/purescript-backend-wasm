-- | Impurification (ADR 0015): `Effect` is opaque, but operationally `Effect a ≃ Unit
-- | -> a` — a thunk you run by applying it. This pass rewrites `Effect`'s three
-- | primitives into that function encoding (a closure that ignores a unit argument),
-- | after which the *general* simplifier collapses an `Effect` `do`-block exactly the
-- | way it collapses a transparent function-newtype monad like `State` — no special
-- | Effect machinery downstream.
-- |
-- |   * `pureE(a)`                 → `\_ -> a`
-- |   * `bindE(m, k)`              → `\_ -> let x = perform(m) in perform(k x)`
-- |   * `unsafePerformEffect(e)`   → `perform(e)`            (perform e = `e(unit)`)
-- |
-- | `do { m; n }`'s `discard` resolves to `bindE` via dictionary elimination, so only
-- | these three need hooking. Runs after dict-elim (which turns `bind`/`pure` over the
-- | `Effect` instance into the `bindE`/`pureE` foreigns); the next simplifier round
-- | reduces the lambdas/applications away.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify
  ( impurifyProgram
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (freeVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (qkey)
import PureScript.CoreFn (Literal(..), Qualified(..))

pureEKey :: String
pureEKey = "Effect.pureE"

bindEKey :: String
bindEKey = "Effect.bindE"

performKey :: String
performKey = "Effect.Unsafe.unsafePerformEffect"

impurifyProgram :: Array M.Module -> Array M.Module
impurifyProgram = map \m -> m { decls = map impurifyBind m.decls }
  where
  impurifyBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go r.expr }) rs)

-- | Rewrite top-down: an *applied* primitive is recognized at the `App` node (so its
-- | head `Var` is not eta-expanded first), recursing into the arguments; an *unapplied*
-- | reference (e.g. the residual `bind = Effect.bindE` alias dict-elim leaves, or
-- | `bindE` sitting inside an instance record) is eta-expanded to its lambda form so it
-- | never reaches lowering as a bare foreign.
go :: M.Expr -> M.Expr
go expr = case expr of
  M.App (M.Var q) args
    | qkey q == Just pureEKey
    , Just { head: a, tail } <- Array.uncons args -> reapply (thunk (go a)) (map go tail)
    | qkey q == Just performKey
    , Just { head: e, tail } <- Array.uncons args -> reapply (perform (go e)) (map go tail)
    | qkey q == Just bindEKey
    , Just { head: m, tail: t1 } <- Array.uncons args
    , Just { head: k, tail: rest } <- Array.uncons t1 -> reapply (thunk (bindBody (go m) (go k))) (map go rest)
  M.Var q
    | qkey q == Just pureEKey -> etaPure
    | qkey q == Just bindEKey -> etaBind
    | qkey q == Just performKey -> etaPerform
  _ -> descend expr

-- | Eta-expansions of the unapplied primitives, into their thunk encoding.
etaPure :: M.Expr
etaPure = M.Abs [ "$a" ] (thunk (local "$a"))

etaBind :: M.Expr
etaBind = M.Abs [ "$m", "$k" ] (thunk (bindBody (local "$m") (local "$k")))

etaPerform :: M.Expr
etaPerform = M.Abs [ "$e" ] (perform (local "$e"))

local :: String -> M.Expr
local n = M.Var (Qualified Nothing n)

descend :: M.Expr -> M.Expr
descend = case _ of
  M.Lit lit -> M.Lit (mapLit go lit)
  e@(M.Var _) -> e
  e@(M.Constructor _ _ _) -> e
  M.Accessor l e -> M.Accessor l (go e)
  M.Update e cf kvs -> M.Update (go e) cf (map (map go) kvs)
  M.Abs ps b -> M.Abs ps (go b)
  M.App f args -> M.App (go f) (map go args)
  M.Case ss alts -> M.Case (map go ss) (map goAlt alts)
  M.Let bs body -> M.Let (map goBind bs) (go body)
  M.Perform e -> M.Perform (go e)
  where
  goAlt alt = alt
    { result = case alt.result of
        Right e -> Right (go e)
        Left gs -> Left (map (\g -> { guard: go g.guard, expression: go g.expression }) gs)
    }
  goBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go r.expr }) rs)

-- | Re-apply any leftover (over-applied) arguments to the rewritten primitive (the
-- | simplifier's app-flattening can merge a `perform`'s applied unit onto a primitive,
-- | e.g. `(bindE(m, k))(unit)` → `bindE(m, k, unit)`, so a recognized `App` may carry
-- | more arguments than the primitive itself takes).
reapply :: M.Expr -> Array M.Expr -> M.Expr
reapply f extra
  | Array.null extra = f
  | otherwise = M.App f extra

-- | A nullary thunk: a closure ignoring its (unit) argument. The binder is chosen not
-- | to occur free in the body, so it is never captured — and it is never referenced.
thunk :: M.Expr -> M.Expr
thunk body = M.Abs [ fresh (allVars body) "$ev" ] body

-- | Run a thunk: the distinct `Perform` node (lowered to applying it to a unit). Kept
-- | distinct from a bare `e(unit)` so the simplifier can reason about a *run*'s purity.
perform :: M.Expr -> M.Expr
perform e = M.Perform e

bindBody :: M.Expr -> M.Expr -> M.Expr
bindBody m k = case k of
  -- common case: the continuation is a literal `\x -> body`, so reuse its binder
  M.Abs [ x ] kbody -> M.Let [ M.NonRec Nothing x (perform m) ] (perform kbody)
  _ ->
    let
      x = fresh (Set.union (allVars m) (allVars k)) "$x"
    in
      M.Let [ M.NonRec Nothing x (perform m) ]
        (perform (M.App k [ M.Var (Qualified Nothing x) ]))

mapLit :: (M.Expr -> M.Expr) -> Literal M.Expr -> Literal M.Expr
mapLit f = case _ of
  LitArray es -> LitArray (map f es)
  LitObject kvs -> LitObject (map (map f) kvs)
  other -> other

allVars :: M.Expr -> Set String
allVars e = Set.fromFoldable (freeVars [] e)

fresh :: Set String -> String -> String
fresh used base = pick 0
  where
  pick i =
    let
      cand = if i == 0 then base else base <> show i
    in
      if Set.member cand used then pick (i + 1) else cand
