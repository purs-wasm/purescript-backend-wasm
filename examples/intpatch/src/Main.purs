-- Orchestrate-path regression fixture for the ADR 0039 wat-only patch `Data.Int` (driven by
-- `purwc/test/diffPurwc.mjs`). `main` reaches `Data.Int`, so under `--orchestrate` the worker
-- over-exports ALL of `Data.Int`'s functions — including `fromNumber`, which calls
-- `Data.Number.isFinite`. Before ADR 0039 the "foreign-only" half-shadow zeroed `Data.Int`'s import
-- surface (it was `libSourced` with no lib corefn), so `Data.Number` was never staged and the worker
-- failed with `unknown callee: Data.Number.isFinite` (blocker ②). Now `Data.Int` keeps its registry
-- corefn (real imports intact); only its foreign comes from the lib, so `Data.Number` is compiled
-- like any other dependency and the program builds + runs standalone.
module Examples.IntPatch.Main where

import Prelude

import Data.Int as Int
import Effect (Effect)
import Effect.Console as Console

main :: Effect Unit
main = Console.log (show (Int.fromString "42"))
