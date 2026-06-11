-- e2e fixture (ADR 0031 phase 5): Array marshalling ($Vals <-> JS array, recursively) both
-- directions through the loader — `twiceAll` is an Array Int -> Array Int export calling the JS
-- `doubleAll` foreign.
module E2E.ForeignArray where

foreign import doubleAll :: Array Int -> Array Int

twiceAll :: Array Int -> Array Int
twiceAll xs = doubleAll xs
