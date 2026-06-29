-- | A dependent module (ADR 0038 M2b): imports `Purwc.Fixture.Dep` and calls its `rotate`
-- | cross-module. `purwc` compiles this consuming ONLY `Dep.pmi` (the interface) — never `Dep.pmo`.
-- | The cross-module call resolves at `wasm-merge` time. Prelude-free, so its only dependency is
-- | `Dep` (no transitive closure to load).
module Purwc.Fixture.User where

import Purwc.Fixture.Dep (Color, rotate)

twice :: Color -> Color
twice c = rotate (rotate c)
