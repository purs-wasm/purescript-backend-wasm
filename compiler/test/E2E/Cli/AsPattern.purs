-- | CLI-driven e2e (ADR 0031 phase 5, regression for #4) of as-patterns (`name@pat`): a head
-- | as-pattern over a deep cons, an as-pattern on a constructor sub-binder, and a named scalar
-- | (literal as-pattern). Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.AsPattern`.)
module Test.E2E.Cli.AsPattern (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "As-patterns (e2e/cli): head / sub-binder / literal -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.AsPattern"))
    $ do
        it "a head as-pattern over a 3-deep cons binds the whole value (len 5)" \inst -> do
          liftEffect (callI32x1 inst "headAs" 5) >>= (_ `shouldEqual` 5)
          liftEffect (callI32x1 inst "headAs" 2) >>= (_ `shouldEqual` (-1))

        it "an as-pattern on a constructor sub-binder binds the tail (sum 10)" \inst -> do
          liftEffect (callI32x1 inst "subAs" 5) >>= (_ `shouldEqual` 10)

        it "a named scalar (literal as-pattern) binds the matched literal" \inst -> do
          liftEffect (callI32x1 inst "litAs" 0) >>= (_ `shouldEqual` 100)
          liftEffect (callI32x1 inst "litAs" 7) >>= (_ `shouldEqual` 7)
