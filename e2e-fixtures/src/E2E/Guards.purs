module E2E.Guards where

import Prelude

-- Two boolean guards sharing one `_` alternative, then a catch-all alternative.
-- When neither guard holds the match falls through to `_ -> 0`.
classify :: Int -> Int
classify n = case n of
  _
    | n > 10 -> 2
    | n > 0 -> 1
  _ -> 0

data Box = Pos Int | Any Int

-- A guarded constructor pattern: the `Pos` tag is switched on first; when the
-- guard fails, matching falls through to the later `Pos _` alternative (the
-- `Any x` alternative does not match a `Pos`).
unbox :: Box -> Int
unbox b = case b of
  Pos x | x > 0 -> x
  Any x -> x
  Pos _ -> 0

-- Int -> Int wrappers so the boxed `Box` never crosses the wasm/JS boundary.
unboxPos :: Int -> Int
unboxPos x = unbox (Pos x)

unboxAny :: Int -> Int
unboxAny x = unbox (Any x)
