-- | The `CountState` counting loop, but written in the **real `Effect` monad** from
-- | the `effect` package — so it exercises `Effect`'s *mutually-recursive* instance
-- | dictionaries (`functorEffect` = `liftA1` → apply/pure; `applyEffect` = `ap` → bind;
-- | `bindEffect`; `monadEffect`). Those cyclic dicts are exactly the case where naive
-- | dictionary passing pays per step; this benchmark measures whether impurification
-- | (ADR 0015) + the simplifier collapse them to the same constant-stack tail loop the
-- | hand-rolled `State` monad gets — i.e. to zero residual closure/dispatch overhead.
-- |
-- | `unsafePerformEffect` runs the (pure) computation, so `countTo :: Int -> Int` is
-- | i32-in/i32-out and needs no marshalling in the harness.
module CountEffect where

import Prelude

import Effect.Unsafe (unsafePerformEffect)

countTo :: Int -> Int
countTo n = unsafePerformEffect (go 0)
  where
  go acc =
    if acc >= n then pure acc
    else pure (acc + 1) >>= go
