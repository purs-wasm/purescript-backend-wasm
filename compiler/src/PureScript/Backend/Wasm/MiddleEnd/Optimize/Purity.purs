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
  , memEffKeys
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

-- | The context the predicates consult: effectful foreign names (seed), the current set of
-- | effectful (impure-running) top-level binding keys, and the set of top-level keys whose
-- | evaluation performs a memory write/alloc (`memEffKeys`).
type PCtx = { eff :: Set String, impure :: Set String, memEff :: Set String }

-- | Evaluating `e` (constructing the value) is free of side effects.
exprPure :: PCtx -> M.Expr -> Boolean
exprPure ctx = not <<< evalImpure ctx

-- | Performing the `Effect` that `e` denotes is free of side effects.
runPure :: PCtx -> M.Expr -> Boolean
runPure ctx = not <<< runImpure ctx

-- | Intrinsics whose *evaluation* carries a memory effect, so they must be treated like a
-- | side-effecting `Perform` by the simplifier's drop/duplicate/reorder guards (all of which
-- | consult `exprPure`): `Wasm.Array.unsafeNew` mints a fresh mutable array (duplicating it
-- | yields *distinct* arrays, so it must not be copied into multiple use sites), and
-- | `Wasm.Array.unsafeSet` writes one in place (so its write must survive even when the
-- | returned array is unused). Without this, a buffer-filling loop that returns a *count*
-- | rather than the array has its `unsafeSet` writes eliminated as dead pure code, and the
-- | array reads back uninitialised — an `illegal cast` at run time (ADR 0026 / 0028).
memoryEffectPrims :: Set String
memoryEffectPrims = Set.fromFoldable [ "Wasm.Array.unsafeNew", "Wasm.Array.unsafeSet" ]

isMemoryEffect :: Qualified String -> Boolean
isMemoryEffect = case _ of
  Qualified (Just m) n -> Set.member (joinWith "." m <> "." <> n) memoryEffectPrims
  Qualified Nothing _ -> false

-- | A top-level (post-lambda-lift) binding whose evaluation writes/allocates (`memEffKeys`).
isMemEffKey :: Set String -> Qualified String -> Boolean
isMemEffKey memEff = case _ of
  Qualified (Just m) n -> Set.member (joinWith "." m <> "." <> n) memEff
  Qualified Nothing _ -> false

evalImpure :: PCtx -> M.Expr -> Boolean
evalImpure ctx = case _ of
  M.Perform e -> runImpure ctx e
  -- an applied (incl. partially applied) memory-effect intrinsic, or a call to a binding whose
  -- evaluation writes memory, evaluates a write/alloc — so it must not be dropped/duplicated
  M.App (M.Var q) _ | isMemoryEffect q || isMemEffKey ctx.memEff q -> true
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
  -- performing an application whose head is a *lambda/let redex* (not a bare producer):
  -- impurify can leave such a redex un-reduced (e.g. `void`/`map`-over-`Effect` becomes
  -- `(λf a. bindE …)(pureE k, modify …)`), and the head reads as a pure value while an
  -- *argument* (`modify …`) is the effect that the lambda performs. Reducing the redex would
  -- expose it, but the syntactic check does not β-reduce; so also treat the app as effectful
  -- when an argument is effectful-to-perform. Over-approximates (an ignored effectful arg is
  -- kept), which is sound — it never drops a real effect (ADR 0019). `App (Var …)` keeps the
  -- precise head-driven rule above, so pure-`Effect`/State collapse is unaffected.
  M.App f args -> runImpure ctx f || any (evalImpure ctx) args || any (runImpure ctx) args
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
      -- `impureKeys` is purely about Effect *performing*; memory writes are not its concern,
      -- so `memEff` is empty here (it is computed separately, by `memEffKeys`).
      ctx = { eff, impure, memEff: Set.empty }
      impure' = Array.foldl (\acc (Tuple k v) -> if bindRunImpure ctx v then Set.insert k acc else acc) impure binds
    in
      if Set.size impure' == Set.size impure then impure else fixpoint impure'

-- | The least-fixpoint set of top-level binding keys whose **evaluation** (when fully applied)
-- | performs a memory write/allocation, propagated through the call graph from the
-- | `Wasm.Array.unsafeNew`/`unsafeSet` prims. Lambda-lifting has already promoted the
-- | buffer-filling local helpers to top level, so this global set reaches them; the simplifier
-- | consults it (via `evalImpure` on an application head) so a binding that merely *fills* an
-- | array — its own result discarded — is neither dropped (when dead) nor moved (when single-use),
-- | because the write must run, in place. Distinct from `impureKeys` (Effect performing, ADR
-- | 0015): a write happens on plain evaluation, never via a `Perform`, so this analysis ignores
-- | `Effect` entirely (a `Perform`'s operand is still scanned, in case it writes).
memEffKeys :: Array M.Module -> Set String
memEffKeys modules = fixpoint Set.empty
  where
  binds = modules >>= \m -> m.decls >>= bindEntries m.name
  fixpoint memEff =
    let
      memEff' = Array.foldl (\acc (Tuple k v) -> if writesMem memEff (stripAbs v) then Set.insert k acc else acc) memEff binds
    in
      if Set.size memEff' == Set.size memEff then memEff else fixpoint memEff'

-- | Does evaluating `e` perform a memory write/alloc — directly via a prim, or by applying a
-- | known memory-effectful binding (`memEff`)? Ignores `Effect` performing (that is
-- | `impureKeys`' concern), so it never over-marks an Effect binding as memory-effectful.
writesMem :: Set String -> M.Expr -> Boolean
writesMem memEff = go
  where
  go = case _ of
    M.App (M.Var q) _ | isMemoryEffect q || isMemEffKey memEff q -> true
    M.App f args -> go f || any go args
    M.Let bs body -> any go (bs >>= bindExprs) || go body
    M.Case ss alts -> any go ss || any (any go <<< altExprs) alts
    M.Accessor _ e -> go e
    M.Update e _ kvs -> go e || any (go <<< snd) kvs
    M.Lit lit -> any go (litExprs lit)
    M.Perform e -> go e
    M.Abs _ _ -> false
    M.Var _ -> false
    M.Constructor _ _ _ -> false

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
