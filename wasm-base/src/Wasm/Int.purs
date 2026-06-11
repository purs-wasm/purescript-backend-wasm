-- | WasmBase `Wasm.Int` (ADR 0026/0028): first-order `Int` primitives, so WasmBase modules —
-- | and ulib shadows of *low-level* prelude modules (e.g. `Data.Functor`, which imports no
-- | arithmetic) — can run without `Prelude` (which would be circular). Types are `Prim`; the
-- | operations resolve to intrinsics on wasm (`Intrinsics.qualifiedIntrinsic` — `Wasm.Int.*`)
-- | and to `Wasm/Int.js` on the JS backends.
module Wasm.Int
  ( add
  , sub
  , mul
  , eq
  , lt
  , div
  , mod
  ) where

foreign import add :: Int -> Int -> Int
foreign import sub :: Int -> Int -> Int
foreign import mul :: Int -> Int -> Int
foreign import eq :: Int -> Int -> Boolean

-- | Signed less-than. On wasm: the `IntLt` intrinsic (`i32.lt_s`).
foreign import lt :: Int -> Int -> Boolean

-- | Euclidean integer division / remainder (matching `Prelude`'s `Int` `EuclideanRing`:
-- | non-negative remainder, `0` when the divisor is `0`). On wasm: the `IntDiv` / `IntMod`
-- | intrinsics. For the non-negative operands the shadows use these on, they are ordinary
-- | quotient / remainder.
foreign import div :: Int -> Int -> Int
foreign import mod :: Int -> Int -> Int
