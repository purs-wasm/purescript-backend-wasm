-- | WasmBase `Wasm.Array` (ADR 0026), PoC placement under `bench/` for measurement — the
-- | real home is a compiler-shipped `wasm-base` package.
-- |
-- | The `foreign import`s are first-order array primitives that resolve to recognized
-- | intrinsics on the wasm backend (`Intrinsics.qualifiedIntrinsic` — `Wasm.Array.*`), so
-- | they need no `.wat`. The accompanying `Wasm/Array.js` provides them for the JS backends
-- | (`purs` / `purs-backend-es`) only.
-- |
-- | `map` / `foldl` are ordinary PureScript over those primitives. Their function argument is
-- | a *static* argument, so ADR 0027's post-inline specialization fuses the closure into a
-- | direct loop (no per-element `call_ref`) — the whole point of writing library HOFs in
-- | PureScript over first-order primitives rather than as foreign `.wat` HOFs.
module Wasm.Array
  ( length
  , unsafeIndex
  , unsafeNew
  , unsafeSet
  , map
  , foldl
  ) where

import Prelude

foreign import length :: forall a. Array a -> Int
foreign import unsafeIndex :: forall a. Array a -> Int -> a
foreign import unsafeNew :: forall a. Int -> Array a
-- | Write `v` at index `i` (mutating in place) and return the array, so a builder loop
-- | threads it — keeping the write live and ordered without needing an effect.
foreign import unsafeSet :: forall a. Array a -> Int -> a -> Array a

map :: forall a b. (a -> b) -> Array a -> Array b
map f xs = go 0 (unsafeNew n)
  where
  n = length xs
  go i out = if i >= n then out else go (i + 1) (unsafeSet out i (f (unsafeIndex xs i)))

foldl :: forall a b. (b -> a -> b) -> b -> Array a -> b
foldl f z xs = go 0 z
  where
  n = length xs
  go i acc = if i >= n then acc else go (i + 1) (f acc (unsafeIndex xs i))
