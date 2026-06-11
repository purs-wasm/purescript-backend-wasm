-- e2e fixture (ADR 0031 phase 5): real `Prelude` `+`/`*`/`-` on `Int`, which desugar through the
-- `Semiring`/`Ring` method accessors and the `semiringInt`/`ringInt` dictionaries down to the
-- `intAdd`/`intMul`/`intSub` intrinsics. Built standalone by `purs-wasm build -e E2E.Arith`; asserted
-- by `Test.E2E.Cli.PreludeArith`. (Migrated from the legacy `Arith` corefn fixture / `PreludeArith`.)
module E2E.Arith where

import Prelude

poly :: Int -> Int -> Int
poly a b = a * a + b * b - a

sumSquares :: Int -> Int -> Int
sumSquares a b = a * a + b * b

diff :: Int -> Int -> Int
diff a b = a - b
