-- | CLI-driven e2e (ADR 0031 phase 5) regression guard for ADR-0015: a discarded
-- | `perform (f x)` of a NON-inlined user-defined `Effect` function must run, across the
-- | three discard combinators (do-notation `bindBody`, `void` `mapBody`, `*>` `applyBody`).
-- | `bump` records its argument; each entry reads the recorded total back, which equals the
-- | sum of the bumped values iff every perform ran exactly once. Before the fix these read 0
-- | — the performs were lowered as partial closures never applied to the perform-unit.
module Test.E2E.Cli.PerformUserEffect (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Performed user Effect fn (e2e/cli): discarded `perform (f x)` of a non-inlined user Effect fn runs across bind/map/apply discard -> purs-wasm build -> run (ADR-0015 regression)"
    $ before (loadExports "E2E.PerformUserEffect")
    $ do
        it "do-notation discard (bindBody): bump 1; bump 10 => 11" \exp -> do
          r <- liftEffect (callI32x1 exp "runBumps" 0)
          r `shouldEqual` 11

        it "void discard (mapBody): void (bump 2) => 2" \exp -> do
          r <- liftEffect (callI32x1 exp "runVoid" 0)
          r `shouldEqual` 2

        it "applySecond discard (applyBody): bump 3 *> bump 4 => 7" \exp -> do
          r <- liftEffect (callI32x1 exp "runSeq" 0)
          r `shouldEqual` 7