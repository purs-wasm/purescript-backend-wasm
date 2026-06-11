-- | CLI-driven e2e (ADR 0031 phase 5) of tail-call elimination: deep top-level self-recursion in
-- | constant stack (1M iterations), an accumulator's value correctness, and a lambda-lifted `where`
-- | loop (with and without a captured free variable). Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.TailCall`.)
module Test.E2E.Cli.TailCall (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Tail-call elimination (e2e/cli): constant-stack recursion -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.TailRec"))
    $ do
        it "runs deep tail recursion in constant stack (no stack overflow)" \inst -> do
          deep <- liftEffect (callI32x1 inst "countdown" 1000000)
          deep `shouldEqual` 42

        it "computes a tail-recursive accumulator correctly" \inst -> do
          s <- liftEffect (callI32x1 inst "run" 100) -- sum 1..100
          s `shouldEqual` 5050

        it "TCEs a lambda-lifted closure self-recursion (the where-go idiom)" \inst -> do
          deep <- liftEffect (callI32x1 inst "loopWhere" 1000000)
          deep `shouldEqual` 1000000

        it "TCEs a lifted closure self-recursion that captures a free variable" \inst -> do
          cap <- liftEffect (callI32x2 inst "loopCapture" 2 500000) -- 2 * 500000
          cap `shouldEqual` 1000000
