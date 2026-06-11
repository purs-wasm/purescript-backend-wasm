module E2E.TailRec where

import Prelude

-- Pure depth test: loops `n` times and returns a constant. Without tail-call
-- elimination this overflows the wasm stack around n = 100_000; with it, it runs
-- in constant stack. `countdown` is a top-level self-recursive function, so its
-- tail self-call is a direct `RCallKnown` — exactly what `return_call` covers.
countdown :: Int -> Int
countdown n = if n == 0 then 42 else countdown (n - 1)

-- Accumulator variant, for value correctness (sum 1..n with i32 wraparound).
sumTo :: Int -> Int -> Int
sumTo acc n = if n == 0 then acc else sumTo (acc + n) (n - 1)

run :: Int -> Int
run n = sumTo 0 n

-- A `where`-bound self-recursive loop (the `fib`/`go` idiom). Its self-call is a
-- *closure* call until lambda-lifting hoists `go` to a top-level supercombinator,
-- after which it is TCE'd like a direct top-level recursion.
loopWhere :: Int -> Int
loopWhere n = go 0 n
  where
  go acc k = if k == 0 then acc else go (acc + 1) (k - 1)

-- `go` here captures a free local (`step`), exercising the lifted supercombinator's
-- leading capture parameter.
loopCapture :: Int -> Int -> Int
loopCapture step n = go 0 n
  where
  go acc k = if k == 0 then acc else go (acc + step) (k - 1)
