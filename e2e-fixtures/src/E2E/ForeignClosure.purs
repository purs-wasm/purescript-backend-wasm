-- e2e fixture (ADR 0031 phase 5): closure marshalling wasm->JS ($Clo -> JS function, ADR 0014) — the
-- wasm passes a closure (\x -> x + 1) to the JS `applyTwice` foreign, which calls it twice. So
-- `useClosure n = applyTwice (\x -> x + 1) n = (n + 1) + 1`.
module E2E.ForeignClosure where

import Prelude

foreign import applyTwice :: (Int -> Int) -> Int -> Int

useClosure :: Int -> Int
useClosure n = applyTwice (\x -> x + 1) n
