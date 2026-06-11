-- | CLI-driven e2e (ADR 0031 phase 5) of a user `foreign import` (ADR 0014): a scalar `Int -> Int`
-- | JS foreign, resolved through the fixture's generated **loader** (`index.mjs`, which bundles the
-- | foreign `.js`) — the real interop deliverable, not a test-supplied import. Built by the real
-- | `purs-wasm build`; loaded and run here. (Migrated from the legacy `Test.E2E.FFI`'s scalar case;
-- | String/Array/Record marshalling follows in later fixtures.)
module Test.E2E.Cli.ForeignImport (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Loader (callI32x1, loadExports)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "User foreign import (e2e/cli): JS Int -> Int via the generated loader -> purs-wasm build -> run"
    $ before (loadExports "E2E.FFIScalar")
    $ do
        it "calls a JS Int -> Int foreign import end-to-end" \exp -> do
          r <- liftEffect (callI32x1 exp "useAddOne" 5)
          r `shouldEqual` 7
          r2 <- liftEffect (callI32x1 exp "useAddOne" 40)
          r2 `shouldEqual` 42
