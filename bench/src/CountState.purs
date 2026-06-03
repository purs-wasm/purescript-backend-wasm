-- | A small `State` monad (state fixed to `Int`) that counts from 0 up to `n`.
-- | Serves both the State-monad benchmark (`bench/count-state.mjs`) and the e2e
-- | stack-safety test: `countTo n` runs in constant stack ONLY if the monad collapses
-- | to a tail loop (newtype transparency, the MIR simplifier reductions, and TCE) —
-- | a deep `n` overflows otherwise (ADR 0015).
-- |
-- | Kept dependency-light on purpose: no `Monad`/`Discard`/`Unit` (the `do`-block uses
-- | only `bind`/`pure` via an explicit `_ <-`, and the state value is an `Int`), so the
-- | fixture links against only the already-committed prelude corefn.
module CountState where

import Prelude

newtype State a = State (Int -> { state :: Int, value :: a })

instance Functor State where
  map f (State g) = State \s ->
    let r = g s in { state: r.state, value: f r.value }

instance Apply State where
  apply (State gf) (State ga) = State \s ->
    let
      rf = gf s
      ra = ga rf.state
    in
      { state: ra.state, value: rf.value ra.value }

instance Applicative State where
  pure a = State \s -> { state: s, value: a }

instance Bind State where
  bind (State g) f = State \s ->
    let r = g s in runState (f r.value) r.state

runState :: forall a. State a -> Int -> { state :: Int, value :: a }
runState (State f) s = f s

evalState :: forall a. State a -> Int -> a
evalState m s = (runState m s).value

get :: State Int
get = State \s -> { state: s, value: s }

put :: Int -> State Int
put s = State \_ -> { state: s, value: s }

countTo :: Int -> Int
countTo fin = evalState (go fin) 0
  where
  go n = do
    i <- get
    if i == n then pure i
    else do
      _ <- put (i + 1)
      go n
