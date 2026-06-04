-- Exercises the `effect` package's control-flow / FFI primitives, each returning a
-- checkable result so a bin-integration test can assert it. The loop bodies use the
-- native `Effect.Ref` core (ADR 0017) to accumulate, avoiding `Console`.
module Examples.EffPrim.Main where

import Prelude

import Effect (Effect, forE, foreachE, untilE, whileE)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn2, runEffectFn2)
import Effect.Unsafe (unsafePerformEffect)

-- forE 0 5: 0+1+2+3+4 = 10
forETest :: Effect Int
forETest = do
  acc <- Ref.new 0
  forE 0 5 \i -> do
    cur <- Ref.read acc
    Ref.write (cur + i) acc
  Ref.read acc

-- foreachE [10,20,30]: 60
foreachETest :: Effect Int
foreachETest = do
  acc <- Ref.new 0
  foreachE [ 10, 20, 30 ] \x -> do
    cur <- Ref.read acc
    Ref.write (cur + x) acc
  Ref.read acc

-- whileE (count < 5): ends at 5
whileETest :: Effect Int
whileETest = do
  i <- Ref.new 0
  whileE (Ref.read i >>= \c -> pure (c < 5)) do
    c <- Ref.read i
    Ref.write (c + 1) i
  Ref.read i

-- untilE: increment until c+1 >= 3, so it writes 1,2,3 and stops → 3
untilETest :: Effect Int
untilETest = do
  i <- Ref.new 0
  untilE do
    c <- Ref.read i
    Ref.write (c + 1) i
    pure (c + 1 >= 3)
  Ref.read i

-- runEffectFn2 (mkEffectFn2 \a b -> pure (a + b)) 3 4 = 7.
-- Written as a do-block (not the bare expression) on purpose: a top-level `Effect a` whose
-- body is a single expression is a CAF holding the thunk, and exporting *that* hits a
-- separate, pre-existing Effect-CAF-export gap. The do-block makes `effFnTest` a performing
-- computation, which is what we want to test here.
effFnTest :: Effect Int
effFnTest = do
  x <- runEffectFn2 (mkEffectFn2 (\a b -> pure (a + b))) 3 4
  pure x

-- unsafePerformEffect (pure 42) = 42
unsafeTest :: Int
unsafeTest = unsafePerformEffect (pure 42)

-- `void` must NOT drop the wrapped effect (ADR 0019): the `modify` runs even though its
-- result is voided, so the cell ends at 5.
voidTest :: Effect Int
voidTest = do
  acc <- Ref.new 0
  void (Ref.modify (_ + 5) acc)
  Ref.read acc

-- `map`/`<#>` over an effectful action must run the action (ADR 0019): `modify` runs
-- (cell → 10), the mapped result is discarded, so the cell is 10.
mapTest :: Effect Int
mapTest = do
  acc <- Ref.new 0
  _ <- (_ + 1) <$> Ref.modify (_ + 10) acc
  Ref.read acc
