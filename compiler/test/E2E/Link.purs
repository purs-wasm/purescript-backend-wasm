-- | End-to-end test of multi-module linking (ADR 0009): two separately-compiled
-- | CoreFn modules are linked into one wasm. `LinkA` imports `LinkB` and calls
-- | across the module boundary — both an ordinary function (`double`) and an ADT
-- | (`Pair`, constructed by `mkPair`, projected by `fstP`) defined in `LinkB`.
-- | Only the root module (`LinkA`) is exported; `LinkB`'s functions are internal.
module Test.E2E.Link (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Linking (e2e): multi-module -> one wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "LinkA" ] ]
                [ "compiler/test/fixtures/LinkA.corefn.json"
                , "compiler/test/fixtures/LinkB.corefn.json"
                ]
            )
        )
    $ do
        -- quadruple x = double (double x)  -- double lives in LinkB
        it "calls a function defined in another module" \inst -> do
          result <- liftEffect (callI32x1 inst "quadruple" 5)
          result `shouldEqual` 20

        -- firstOfPair n = fstP (mkPair n 999)  -- Pair / mkPair / fstP all in LinkB
        it "constructs and projects an ADT defined in another module" \inst -> do
          result <- liftEffect (callI32x1 inst "firstOfPair" 7)
          result `shouldEqual` 7
