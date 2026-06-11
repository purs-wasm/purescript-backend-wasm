-- | CLI-driven e2e (ADR 0031 phase 5) of type-class dictionary passing — dictionary passing: dispatching a class method
-- | through a passed dictionary and projecting a nullary method from an instance CAF, plus superclass
-- | access (one- and two-level superclass hops, via the separate `E2E.Slice3b` fixture). Built
-- | standalone by the real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.Slice3`.)
module Test.E2E.Cli.TypeClasses (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "TypeClasses (e2e/cli): dictionary-passing -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.TypeClasses"))
    $ do
        it "dispatches a class method through a passed dictionary" \inst -> do
          result <- liftEffect (callI32x1 inst "doubleInt" 21)
          result `shouldEqual` 42

        it "projects a nullary method and a method from an instance CAF" \inst -> do
          result <- liftEffect (callI32x0 inst "sumNil")
          result `shouldEqual` 0

  describe "TypeClasses (e2e/cli): superclass access -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.TypeClassesSuper"))
    $ do
        it "reaches a one-level superclass dictionary" \inst -> do
          result <- liftEffect (callI32x1 inst "viaDerivedOf" 7)
          result `shouldEqual` 7

        it "reaches a two-level superclass dictionary" \inst -> do
          result <- liftEffect (callI32x1 inst "viaTopOf" 42)
          result `shouldEqual` 42
