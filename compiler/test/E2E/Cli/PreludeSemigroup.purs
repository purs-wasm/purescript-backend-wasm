-- | CLI-driven e2e (ADR 0031 phase 5) of `Semigroup` `<>`: `String` concatenation and `Array` append
-- | (length + element order preserved). Built standalone by the real `purs-wasm build`. (Migrated
-- | from the legacy corefn-fixture `Test.E2E.PreludeSemigroup`.)
module Test.E2E.Cli.PreludeSemigroup (spec) where

import Prelude

import Data.Traversable (traverse)
import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Semigroup <> (e2e/cli): String concat + Array append -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Sgp"))
    $ do
        it "concatenates Strings (\"foo\" <> \"bar\" == \"foobar\")" \inst -> do
          ok <- liftEffect (callI32x0 inst "strOk")
          ok `shouldEqual` 1

        it "concatenates Arrays (length of [1,2,3] <> [4,5])" \inst -> do
          n <- liftEffect (callI32x0 inst "arrLen")
          n `shouldEqual` 5

        it "preserves Array element order across the join ([10,20] <> [30,40])" \inst -> do
          xs <- liftEffect (traverse (callI32x1 inst "arrAt") [ 0, 1, 2, 3 ])
          xs `shouldEqual` [ 10, 20, 30, 40 ]
