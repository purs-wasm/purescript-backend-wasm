-- | CLI-driven e2e (ADR 0031 phase 5) that the middle-end's **purity analysis** preserves effect
-- | semantics (ADR 0015): `incrCtr`/`readCtr` are backed by a mutable wasm global (the `IncrCtr`/
-- | `ReadCtr` intrinsics, so the artifact is standalone). Count preservation — three increments per
-- | call, read back as 3/6/9 across repeated calls on one instance — and order preservation
-- | (interleaved reads ⇒ 12 on a fresh instance). A purity-blind optimizer would drop or reorder the
-- | effects. Built standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture
-- | `Test.E2E.Counter`.)
module Test.E2E.Cli.Counter (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "Effect purity (e2e/cli): effectful runs are preserved (ADR 0015) -> purs-wasm build -> run" do
  -- each `before` re-instantiates the module, so the mutable global starts fresh at 0.
  before (liftEffect (cliFixture "E2E.Counter")) $
    it "preserves effect count (three incrs per call: 3, 6, 9)" \inst -> do
      r1 <- liftEffect (callI32x1 inst "countThree" 0)
      r1 `shouldEqual` 3
      r2 <- liftEffect (callI32x1 inst "countThree" 0)
      r2 `shouldEqual` 6
      r3 <- liftEffect (callI32x1 inst "countThree" 0)
      r3 `shouldEqual` 9

  before (liftEffect (cliFixture "E2E.Counter")) $
    it "preserves effect order (interleaved reads => 12)" \inst -> do
      r <- liftEffect (callI32x1 inst "order" 0)
      r `shouldEqual` 12
