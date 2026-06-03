module Example.FFI where

-- A user-defined `foreign import` (ADR 0014): `addOne`'s implementation is the JS
-- in `FFI.js`. The backend resolves it to a wasm host import that the generated
-- `index.mjs` loader satisfies from `foreign/Example.FFI.js`.
foreign import addOne :: Int -> Int

useAddOne :: Int -> Int
useAddOne n = addOne (addOne n)
