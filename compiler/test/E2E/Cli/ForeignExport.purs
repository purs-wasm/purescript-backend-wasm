-- | CLI-driven e2e (ADR 0031 phase 5) of wasm **export** marshalling (ADR 0014) and export arity
-- | through the generated loader: a `Boolean` (i31 ↔ JS boolean) and `Number` (raw f64) export,
-- | nullary value bindings (`Int` / marshalled `String`, exposed as the value itself), and a
-- | point-free (partially-applied) export called as a 1-ary function. Built standalone by the real
-- | `purs-wasm build`. (Migrated from the legacy `Test.E2E.FFIExport` / `Test.E2E.PointFree` non-record
-- | cases; String/Array are in `ForeignMarshal`, Record marshalling is the deferred gap.)
module Test.E2E.Cli.ForeignExport (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, callJson, getJson, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Export marshalling & arity (e2e/cli): Boolean/Number/nullary/point-free -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignExport")
    $ do
        it "marshals a Boolean result (i31 <-> JS boolean)" \exp -> do
          t <- liftEffect (callJson exp "isPos" """[5]""")
          f <- liftEffect (callJson exp "isPos" """[-2]""")
          [ t, f ] `shouldEqual` [ "true", "false" ]

        it "passes a Number through the raw f64 ABI" \exp -> do
          r <- liftEffect (callJson exp "half" """[7.0]""")
          r `shouldEqual` "3.5"

        it "evaluates nullary value bindings (Int and marshalled String)" \exp -> do
          i <- liftEffect (getJson exp "answer")
          s <- liftEffect (getJson exp "greeting")
          [ i, s ] `shouldEqual` [ "42", "\"hi\"" ]

        it "calls a point-free (partially-applied) export as a 1-ary function" \exp -> do
          r <- liftEffect (callI32x1 exp "addTen" 5)
          r `shouldEqual` 15
