-- | CLI-driven e2e (ADR 0031 phase 5) of `Data.Int.fromNumber`/`toNumber`: an `Int -> Number -> Int`
-- | round-trip recovers the value (the `Just` closure is applied). Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.IntConv`.)
module Test.E2E.Cli.IntConv (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Data.Int conversions (e2e/cli): fromNumber / toNumber round-trip -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.IntConv"))
    $ do
        it "recovers the Int through fromNumber (the just closure is applied)" \inst -> do
          liftEffect (callI32x1 inst "roundtrip" 42) >>= (_ `shouldEqual` 42)
          liftEffect (callI32x1 inst "roundtrip" 0) >>= (_ `shouldEqual` 0)
          liftEffect (callI32x1 inst "roundtrip" (-7)) >>= (_ `shouldEqual` (-7))
