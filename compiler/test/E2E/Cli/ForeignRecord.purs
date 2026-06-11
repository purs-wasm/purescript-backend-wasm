-- | CLI-driven e2e (ADR 0031 phase 5) of Record host-marshalling ($Rec <-> JS object, ADR 0014),
-- | declared through a TYPE SYNONYM (`type Point = { x, y }`). Regression guard for the externs
-- | synonym-expansion fix: before it, an alias-typed record foreign marshalled as opaque and trapped.
-- | `pointX`/`pointY` cross the foreign boundary; `bump` the export boundary (record arg + result).
module Test.E2E.Cli.ForeignRecord (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, callJson, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Foreign Record marshalling (e2e/cli): $Rec <-> JS object via a type synonym -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignRecord")
    $ do
        it "marshals a record across the foreign boundary (field read back as Int)" \exp -> do
          x <- liftEffect (callI32x1 exp "pointX" 5)
          y <- liftEffect (callI32x1 exp "pointY" 5)
          [ x, y ] `shouldEqual` [ 6, 6 ]

        it "marshals a record arg + result across the export boundary" \exp -> do
          r <- liftEffect (callJson exp "bump" """[{"x":5,"y":7}]""")
          r `shouldEqual` """{"x":6,"y":7}"""
