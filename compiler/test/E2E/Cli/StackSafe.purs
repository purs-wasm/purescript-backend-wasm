-- | CLI-driven e2e (ADR 0031 phase 5) **stack-safety** test: a `State`-monad loop run for a million
-- | iterations completes in constant stack ONLY if the monad collapses to a tail loop (newtype
-- | transparency + the MIR simplifier reductions + TCE all fire). A regression rebuilds an O(n) stack
-- | and overflows, so this guards that the *optimization happened* (ADR 0015) — not just the value.
-- | Built standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture
-- | `Test.E2E.StackSafe`; the fixture is the shared `bench` `CountState`.)
module Test.E2E.Cli.StackSafe (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "State-monad stack safety (e2e/cli): a million iterations -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.CountState"))
    $ do
        it "runs a million State iterations without overflowing" \inst -> do
          r <- liftEffect (callI32x1 inst "countTo" 1000000)
          r `shouldEqual` 1000000

        it "is correct for a small count too" \inst -> do
          r <- liftEffect (callI32x1 inst "countTo" 42)
          r `shouldEqual` 42
