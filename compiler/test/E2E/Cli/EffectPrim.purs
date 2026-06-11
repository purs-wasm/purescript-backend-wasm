-- | CLI-driven e2e (ADR 0031 phase 5) of effect primitives (ADR 0015/0017/0019): `void` must NOT drop
-- | the wrapped effect (`Ref.modify` still runs), and `forE` runs its cross-module `Ref.modify` body
-- | each iteration. Native `Effect`/`Effect.Ref` (no host import), built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.EffectPrim`.)
module Test.E2E.Cli.EffectPrim (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Effect primitives (e2e/cli): void + forE over Ref -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.EffP"))
    $ do
        it "void preserves the discarded effect (acc ends at 5)" \inst -> do
          r <- liftEffect (callI32x0 inst "voidTest")
          r `shouldEqual` 5

        it "forE runs the cross-module Ref.modify body each iteration (5 x +2 = 10)" \inst -> do
          r <- liftEffect (callI32x0 inst "forETest")
          r `shouldEqual` 10
