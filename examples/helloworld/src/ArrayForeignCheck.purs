-- Regression fixture for the ulib `Data.Array` shadow's KEPT FOREIGNS (ADR 0028/0031): unlike the
-- pure-PS array HOFs in `ArrayShadowCheck`, these (`reverse` / `sliceImpl` / `indexImpl` /
-- `unconsImpl` / `rangeImpl` / `length`) stay as wasm `foreign import`s, provided by the lib's
-- `$LIB/Data.Array/foreign.wasm`. This guards that the build reconstructs their calling-convention
-- signatures correctly and the merged provider runs — standalone (no JS host import). Crucially the
-- polymorphic readers are the ones whose arity externs alone supposedly cannot reconstruct, so this
-- is the fixture that proves whether the build still needs the `ulib/<M>/foreign.wat` sig source.
-- Driven by `compiler/test/arrayForeign.mjs`.
-- |
-- `check n` returns a 6-bit pass mask (63 = all pass). Arrays are built from the runtime argument so
-- the optimizer cannot constant-fold the checks away — the foreign loops must actually run on wasm.
module Examples.HelloWorld.ArrayForeignCheck where

import Prelude

import Data.Array (length, range, reverse, slice, index, uncons)
import Data.Maybe (Maybe(..))

check :: Int -> Int
check n = b0 + b1 * 2 + b2 * 4 + b3 * 8 + b4 * 16 + b5 * 32
  where
  xs = range n (n + 4) -- rangeImpl → [n, n+1, n+2, n+3, n+4]
  b0 = if reverse xs == [ n + 4, n + 3, n + 2, n + 1, n ] then 1 else 0 -- reverse
  b1 = if slice 1 3 xs == [ n + 1, n + 2 ] then 1 else 0 -- sliceImpl
  b2 = if index xs 2 == Just (n + 2) then 1 else 0 -- indexImpl (in bounds)
  b3 = if index xs 10 == Nothing then 1 else 0 -- indexImpl (out of bounds)
  b4 = case uncons xs of
    Just { head, tail } -> if head == n && length tail == 4 then 1 else 0 -- unconsImpl + length
    Nothing -> 0
  b5 = if length xs == 5 then 1 else 0 -- length
