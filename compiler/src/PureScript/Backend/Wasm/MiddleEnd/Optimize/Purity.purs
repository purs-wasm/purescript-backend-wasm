-- | Whole-program purity analysis (ADR 0015). After impurification, running an
-- | `Effect` is a `Perform` node; the simplifier must not drop, reorder, or duplicate
-- | an *effectful* `Perform`, but is free to collapse a *pure* one. This module decides
-- | which is which.
-- |
-- | Two notions, mutually recursive:
-- |
-- |   * `evalImpure` — does **evaluating** an expression (constructing it) run an
-- |     effect? Only a `Perform` of an effectful operand does; lambdas are delayed
-- |     values, so their bodies are not evaluated here.
-- |   * `runImpure` — does **performing** the `Effect` an expression denotes run an
-- |     effect? A thunk `\$ev -> b` runs `b`; an applied/var effect-producer defers to
-- |     whether that producer is effectful (`headImpure`).
-- |
-- | `headImpure` consults the seed set of effectful foreigns and the
-- | least-fixpoint set of effectful (impure-running) top-level bindings: a *local*
-- | variable being performed is opaque, hence conservatively effectful. `impureKeys`
-- | is that fixpoint — a binding is effectful if running its (fully applied) value runs
-- | an effect, seeded by the effectful foreigns and opaque performs. A top-level name
-- | absent from the set is pure-running, so an `Effect` loop like `go$lift0` (which only
-- | performs itself) stays pure and collapses.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity
  ( PCtx
  , impureKeys
  , exprPure
  , runPure
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (any)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Literal(..), Qualified(..))

-- | The context the predicates consult: effectful foreign names (seed) and the current
-- | set of effectful (impure-running) top-level binding keys.
type PCtx = { eff :: Set String, impure :: Set String }

-- | Evaluating `e` (constructing the value) is free of side effects.
exprPure :: PCtx -> M.Expr -> Boolean
exprPure ctx = not <<< evalImpure ctx

-- | Performing the `Effect` that `e` denotes is free of side effects.
runPure :: PCtx -> M.Expr -> Boolean
runPure ctx = not <<< runImpure ctx

evalImpure :: PCtx -> M.Expr -> Boolean
evalImpure ctx = case _ of
  M.Perform e -> runImpure ctx e
  M.App f args -> evalImpure ctx f || any (evalImpure ctx) args
  M.Let bs body -> any (evalImpure ctx) (bs >>= bindExprs) || evalImpure ctx body
  M.Case ss alts -> any (evalImpure ctx) ss || any (any (evalImpure ctx) <<< altExprs) alts
  M.Accessor _ e -> evalImpure ctx e
  M.Update e _ kvs -> evalImpure ctx e || any (evalImpure ctx <<< snd) kvs
  M.Lit lit -> any (evalImpure ctx) (litExprs lit)
  M.Abs _ _ -> false -- a delayed value; its body runs only when performed
  M.Var _ -> false
  M.Constructor _ _ _ -> false

runImpure :: PCtx -> M.Expr -> Boolean
runImpure ctx = case _ of
  -- a thunk: performing it runs its body. A multi-parameter thunk yields a (pure)
  -- function value when performed once, so only the single-parameter case runs.
  M.Abs [ _ ] b -> evalImpure ctx b
  M.Abs _ _ -> false
  -- performing an applied / bare effect-producer: effectful iff the producer is, plus
  -- any effects from constructing the arguments
  M.App (M.Var q) args -> headImpure ctx q || any (evalImpure ctx) args
  M.App f args -> runImpure ctx f || any (evalImpure ctx) args
  M.Var q -> headImpure ctx q
  M.Let bs body -> any (evalImpure ctx) (bs >>= bindExprs) || runImpure ctx body
  M.Case ss alts -> any (evalImpure ctx) ss || any (any (runImpure ctx) <<< altExprs) alts
  M.Perform e -> runImpure ctx e
  _ -> true -- opaque (a literal, accessor, …): conservatively effectful

headImpure :: PCtx -> Qualified String -> Boolean
headImpure ctx = case _ of
  Qualified (Just m) n -> let k = joinWith "." m <> "." <> n in Set.member k ctx.eff || Set.member k ctx.impure
  Qualified Nothing _ -> true -- a local being performed is opaque

-- | The least-fixpoint set of effectful (impure-running) top-level binding keys.
impureKeys :: Set String -> Array M.Module -> Set String
impureKeys eff modules = fixpoint Set.empty
  where
  binds :: Array (Tuple String M.Expr)
  binds = modules >>= \m -> m.decls >>= bindEntries m.name

  fixpoint impure =
    let
      ctx = { eff, impure }
      impure' = Array.foldl (\acc (Tuple k v) -> if bindRunImpure ctx v then Set.insert k acc else acc) impure binds
    in
      if Set.size impure' == Set.size impure then impure else fixpoint impure'

-- | A binding is effectful if running its fully-applied value runs an effect. Strip
-- | the binding's parameters (the trailing one is the `perform` unit) to reach the
-- | performed body, then ask whether **evaluating** it runs an effect. The extra
-- | `producerImpure` covers a point-free alias whose body is *itself* an effect
-- | producer (e.g. `myLog = log`): there is no `Perform` to find, so consult the head
-- | directly. (Not folded into `evalImpure`/`runImpure`: the performed body is a value,
-- | so recursing it as an `Effect` would misread a plain result like `acc` as a run.)
bindRunImpure :: PCtx -> M.Expr -> Boolean
bindRunImpure ctx v =
  let
    inner = stripAbs v
  in
    evalImpure ctx inner || producerImpure ctx inner

-- | A bare effect-producer head (a point-free binding's body): effectful iff the head
-- | is. Anything else is handled by `evalImpure`, so it is not a producer here.
producerImpure :: PCtx -> M.Expr -> Boolean
producerImpure ctx = case _ of
  M.Var q -> headImpure ctx q
  M.App (M.Var q) _ -> headImpure ctx q
  _ -> false

stripAbs :: M.Expr -> M.Expr
stripAbs = case _ of
  M.Abs _ b -> stripAbs b
  e -> e

bindEntries :: Array String -> M.Bind -> Array (Tuple String M.Expr)
bindEntries mn = case _ of
  M.NonRec _ i e -> [ Tuple (keyOf mn i) e ]
  M.Rec rs -> map (\r -> Tuple (keyOf mn r.ident) r.expr) rs

keyOf :: Array String -> String -> String
keyOf mn i = joinWith "." mn <> "." <> i

bindExprs :: M.Bind -> Array M.Expr
bindExprs = case _ of
  M.NonRec _ _ e -> [ e ]
  M.Rec rs -> map _.expr rs

altExprs :: M.Alt -> Array M.Expr
altExprs alt = case alt.result of
  Right e -> [ e ]
  Left gs -> gs >>= \g -> [ g.guard, g.expression ]

litExprs :: Literal M.Expr -> Array M.Expr
litExprs = case _ of
  LitArray es -> es
  LitObject kvs -> map snd kvs
  _ -> []
