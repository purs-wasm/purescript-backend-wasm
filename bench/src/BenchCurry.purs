-- | Curry-vs-uncurry microbenchmark for the wasm backend.
-- |
-- | Both `curryDispatch` and `uncurryDispatch` compute the *same* checksum by applying a
-- | ternary integer op `n` times. The op is fetched from an array by a runtime index
-- | (`k `mod` 4`), so neither backend can see *which* op is applied at the call site and
-- | therefore cannot specialize the application away:
-- |
-- |   * `curryDispatch` keeps the op curried (`Int -> Int -> Int -> Int`). In JS this is
-- |     `op(a)(b)(c)` — two intermediate closures allocated per call (the currying cost).
-- |   * `uncurryDispatch` uses `Fn3` (`runFn3 op a b c` -> `op(a, b, c)`) — a single
-- |     3-arg call, no intermediate closures.
-- |
-- | In our wasm backend `mkFn3` is the identity and `runFn3` is the saturated apply — the
-- | same lowering a saturated curried application already gets — so the two should match.
-- | The point of the benchmark: idiomatic curried code costs nothing extra on wasm,
-- | whereas JS pays a per-call closure-allocation tax for currying. Driven by
-- | `bench/curry.mjs`.
module BenchCurry where

import Prelude

import Data.Array as Array
import Data.Function.Uncurried (Fn3, mkFn3, runFn3)
import Partial.Unsafe (unsafePartial)

-- A small bank of ternary ops behind an array. The curried and uncurried banks compute
-- identical bodies, so the two dispatch loops return the same checksum on every backend.
curriedOps :: Array (Int -> Int -> Int -> Int)
curriedOps =
  [ \a b c -> a + b + c
  , \a b c -> a * b + c
  , \a b c -> a + b * c
  , \a b c -> (a - b) + c
  ]

uncurriedOps :: Array (Fn3 Int Int Int Int)
uncurriedOps =
  [ mkFn3 \a b c -> a + b + c
  , mkFn3 \a b c -> a * b + c
  , mkFn3 \a b c -> a + b * c
  , mkFn3 \a b c -> (a - b) + c
  ]

-- Apply a curried op fetched by a runtime index `n` times; the index keeps the op
-- opaque so the application stays `op(a)(b)(c)` (two intermediate closures in JS).
curryDispatch :: Int -> Int
curryDispatch n = go n 0
  where
  go k acc =
    if k == 0 then acc
    else
      let
        op = unsafePartial (Array.unsafeIndex curriedOps (k `mod` 4))
      in
        go (k - 1) (acc + op k (k + 1) (k + 2))

-- The same computation through `Fn3` — a single saturated `op(a, b, c)` call, no
-- intermediate closures.
uncurryDispatch :: Int -> Int
uncurryDispatch n = go n 0
  where
  go k acc =
    if k == 0 then acc
    else
      let
        op = unsafePartial (Array.unsafeIndex uncurriedOps (k `mod` 4))
      in
        go (k - 1) (acc + runFn3 op k (k + 1) (k + 2))
