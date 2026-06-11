-- e2e fixture (ADR 0031 phase 5): a scalar `Int -> Int` user `foreign import` (ADR 0014). The CLI
-- bundles the sibling `.js` into the generated loader, so `Test.E2E.Cli.ForeignImport` runs it
-- through the real interop path. `useAddOne n = addOne n + 1` (addOne = +1, so useAddOne = +2).
module E2E.FFIScalar where

import Prelude

foreign import addOne :: Int -> Int

useAddOne :: Int -> Int
useAddOne n = addOne n + 1
