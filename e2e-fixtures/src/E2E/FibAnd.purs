-- A cyclic top-level CAF (ADR 0006): `fibAnd` is an arity-0 *value* (not a function)
-- that references **itself**, so it forms a value-level cycle and must NOT be globalized
-- — it stays a getter function. Adapted from a PureScript-Discord example that used
-- `Data.Tuple`; a local two-field `data` wrapper keeps `fibAnd` a genuine value (a
-- `newtype` would erase to a plain function and stop being a CAF). The self-reference is
-- under the lambda, so it is well-defined (`purs` rejects a construction-time cycle like
-- `x = x + 1`). The guard: globalization correctly excludes `fibAnd`, and `fib` still runs.
module E2E.FibAnd where

import Prelude

data Fib = Fib String (Int -> Int)

fibAnd :: Fib
fibAnd = Fib "fib" \n ->
  if n < 2 then n
  else (case fibAnd of Fib _ f -> f (n - 1)) + (case fibAnd of Fib _ f -> f (n - 2))

fib :: Int -> Int
fib n = case fibAnd of Fib _ f -> f n
