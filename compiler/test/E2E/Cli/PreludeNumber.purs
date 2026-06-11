-- | CLI-driven e2e (ADR 0031 phase 5) of `Number` arithmetic (f64 `+`/`*`/`-`/`/`), checked against
-- | the `Int` result and the `(a/b)*b == a` identity. Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.PreludeNumber`.)
module Test.E2E.Cli.PreludeNumber (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Number arithmetic (e2e/cli): + * - / on f64 -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Num"))
    $ do
        it "adds / multiplies / subtracts Numbers (matching the Int result)" \inst -> do
          a <- liftEffect (callI32x2 inst "addOk" 3 4)
          m <- liftEffect (callI32x2 inst "mulOk" 5 6)
          s <- liftEffect (callI32x2 inst "subOk" 9 4)
          [ a, m, s ] `shouldEqual` [ 1, 1, 1 ]

        it "divides Numbers (f64.div, checked by (a/b)*b == a)" \inst -> do
          x <- liftEffect (callI32x2 inst "divOk" 10 4)
          y <- liftEffect (callI32x2 inst "divOk" 6 2)
          [ x, y ] `shouldEqual` [ 1, 1 ]
