module E2E.Eff where

import Prelude

import Effect.Unsafe (unsafePerformEffect)

-- A pure Effect computation (no foreign effects). `unsafePerformEffect` runs it, so
-- after impurification (ADR 0015) the whole do-block must collapse to plain
-- arithmetic: `runEff n = n + 1`. The e2e test pins that it both collapses and runs.
runEff :: Int -> Int
runEff n = unsafePerformEffect do
  x <- pure n
  y <- pure 1
  pure (x + y)

-- Functor (functorEffect.map = liftA1, which routes through apply + pure)
mapEff :: Int -> Int
mapEff n = unsafePerformEffect (map (\x -> x + 1) (pure n))

-- Apply (applyEffect.apply = ap, which routes through bind) + Applicative (pure)
applyEff :: Int -> Int -> Int
applyEff a b = unsafePerformEffect ((\x y -> x + y) <$> pure a <*> pure b)

-- Bind, explicit (>>=)
bindEff :: Int -> Int
bindEff n = unsafePerformEffect (pure n >>= \x -> pure (x * 2))

-- A pure Effect *loop* (recursion through bind): the cyclic-dict stress case — must
-- collapse to a constant-stack tail loop the way the State monad does, or the
-- mutually-recursive Effect instance dicts leave residual closures.
countEff :: Int -> Int
countEff n = unsafePerformEffect (go 0)
  where
  go acc =
    if acc >= n then pure acc
    else pure (acc + 1) >>= go
