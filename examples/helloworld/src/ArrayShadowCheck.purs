-- Regression fixture for the ulib `Control.Apply` / `Control.Bind` / `Data.Eq` / `Data.Ord` shadows
-- (ADR 0028): each reimplements its array HOF foreign (`arrayApply` / `arrayBind` / `eqArrayImpl` /
-- `ordArrayImpl`) in PureScript over `Wasm.Array`, so the element closure specializes. `ulib check`
-- guards the *interface*; this guards the *runtime semantics* of those hand-written loops via the
-- `purs-wasm build` CLI (the only path that applies the shadow swap). Driven by `compiler/test/
-- ulibShadow.mjs`.
-- |
-- `check n` returns a 4-bit pass mask (15 = all pass): bit0 apply, bit1 bind, bit2 eq, bit3 ord.
-- The arrays are built from the runtime argument `n` so the optimizer cannot constant-fold the
-- checks away — the shadow code must actually run on wasm.
module Examples.HelloWorld.ArrayShadowCheck where

import Prelude

check :: Int -> Int
check n = c1 + c2 * 2 + c3 * 4 + c4 * 8
  where
  -- Control.Apply: Array `<*>` — every function applied to every element (length fs * length xs)
  applyR = [ (_ + n), (_ * 2) ] <*> [ 10, 20 ]
  c1 = if applyR == [ 10 + n, 20 + n, 20, 40 ] then 1 else 0
  -- Control.Bind: Array `>>=` — concatMap, flattening each sub-array in order
  bindR = [ n, n + 1 ] >>= \x -> [ x, x * 10 ]
  c2 = if bindR == [ n, n * 10, n + 1, (n + 1) * 10 ] then 1 else 0
  -- Data.Eq: Array `==` — equal, unequal element, unequal length (all must hold)
  c3 = if ([ n, 2, 3 ] == [ n, 2, 3 ]) && not ([ n, 2 ] == [ n, 3 ]) && not ([ n, 2 ] == [ n, 2, 3 ]) then 1 else 0
  -- Data.Ord: Array `compare` — element delta, equal, and prefix (shorter < longer)
  c4 =
    if
      (compare [ n, 2 ] [ n, 3 ] == LT)
        && (compare [ n, 2 ] [ n, 2 ] == EQ)
        && (compare [ n, 2, 3 ] [ n, 2 ] == GT)
        && (compare [ n, 2 ] [ n, 2, 3 ] == LT) then 1
    else 0
