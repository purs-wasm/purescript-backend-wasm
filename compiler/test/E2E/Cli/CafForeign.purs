-- | CLI-driven e2e (ADR 0021): regression for the Gap B fix — a top-level CAF whose init calls a
-- | JS foreign returning a non-scalar value, so the result is marshalled back into wasm (a re-entry
-- | into the instance). The loader runs `$caf_init` AFTER instantiation, so this works; the old
-- | wasm-`start`-section init trapped at load (the instance was not yet bound). Loaded via the
-- | generated loader (the foreign needs it).
module Test.E2E.Cli.CafForeign (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "CAF init via a re-entrant foreign (e2e/cli): top-level CAF marshals a JS foreign result -> purs-wasm build -> run"
    $ before (loadExports "E2E.CafForeign")
    $ do
        it "initializes a CAF whose init marshals an Array result from a JS foreign (Gap B fix)" \exp -> do
          n <- liftEffect (callI32x1 exp "numsSum" 0)
          n `shouldEqual` 33
