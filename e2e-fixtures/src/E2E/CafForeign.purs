-- | Regression for the Gap B fix (CAF init runs via the loader, after instantiation — ADR 0021):
-- | a **top-level CAF** whose initializer calls a JS foreign that returns a non-scalar value, so
-- | the result is marshalled back into wasm (a re-entry into the instance's exports). With the old
-- | wasm-`start`-section CAF init this trapped at load (the instance was not yet bound); now the
-- | loader runs `$caf_init` after instantiation, so it works. Uses only local JS foreigns + `Prim`
-- | `Array`, no library deps.
module E2E.CafForeign where

foreign import range3 :: Int -> Array Int

foreign import arrSum :: Array Int -> Int

-- | The CAF: its init calls `range3` and marshals the `Array Int` result back into wasm.
nums :: Array Int
nums = range3 10

-- | Host entry: sum the CAF array (10 + 11 + 12). Expect 33.
numsSum :: Int -> Int
numsSum _ = arrSum nums
