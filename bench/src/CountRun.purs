-- | The Run/State analogue of `CountState`: counts 0..n over purescript-run's STATE effect,
-- | so the benchmark exercises the Run/Free interpreter loop — in particular the eta-expanded
-- | point-free recursive `loop` bindings in `Run.run`/`runState`. `countTo n == n`. Compared
-- | against the hand-rolled `CountState` (and the JS backends) to gauge the eta-expansion's
-- | per-step sharing-loss cost (bench/count-run.mjs).
module CountRun where

import Prelude

import Data.Tuple (Tuple(..))
import Run (Run, extract)
import Run.State (STATE, get, put, runState)
import Type.Row (type (+))

countTo :: Int -> Int
countTo fin = case extract (runState 0 (go fin)) of Tuple s _ -> s
  where
  go :: Int -> Run (STATE Int + ()) Int
  go n = do
    i <- get
    if i == n then pure i
    else do
      _ <- put (i + 1)
      go n
