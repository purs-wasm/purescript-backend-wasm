-- | CLI-driven e2e (ADR 0031 phase 5) of host-interop **marshalling** (ADR 0014) through the
-- | fixture's generated loader, in BOTH directions: a `String`/`Array` export (export-side
-- | marshalling of the arg + result) whose body calls a JS foreign of the same type (import-side
-- | marshalling). `callJson` passes/returns JSON-able JS values, so the loader's `$Str`/`$Vals`
-- | conversion is exercised end to end. (Migrated from the legacy `Test.E2E.FFI`'s String/Array
-- | cases; the closure case is below. Record marshalling lives in `Test.E2E.Cli.ForeignRecord`.)
module Test.E2E.Cli.ForeignMarshal (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, callJson, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "Foreign String marshalling (e2e/cli): $Str <-> JS string -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignString")
    $ do
        it "marshals a String arg + result both ways (greet b = uppercase \"hi b\")" \exp -> do
          r <- liftEffect (callJson exp "greet" """["bob"]""")
          r `shouldEqual` "\"HI BOB\""

  describe "Foreign Array marshalling (e2e/cli): $Vals <-> JS array -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignArray")
    $ do
        it "marshals an Array Int arg + result both ways (twiceAll doubles each)" \exp -> do
          r <- liftEffect (callJson exp "twiceAll" """[[1,2,3]]""")
          r `shouldEqual` "[2,4,6]"

  describe "Foreign closure marshalling (e2e/cli): $Clo -> JS function (wasm->JS) -> purs-wasm build -> run"
    $ before (loadExports "E2E.ForeignClosure")
    $ do
        it "passes a wasm closure to a JS foreign that applies it twice (n+1+1)" \exp -> do
          r <- liftEffect (callI32x1 exp "useClosure" 5)
          r `shouldEqual` 7
