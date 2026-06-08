-- | Regression guard for #4: an **as-pattern** (`name@pat`) at a clause/`case` head was
-- | silently not matched (the alternative was dropped, so e.g. `Data.List.map` returned
-- | `Nil` for ≥3-element lists). Checks a head as-pattern over a 3-deep cons, an as-pattern
-- | on a constructor sub-binder, and a named scalar — all compiled to wasm and run.
module Test.E2E.AsPattern (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "as-patterns (e2e, #4): `x@pat` at a clause head -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "AsPattern" ] ]
                [ "compiler/test/fixtures/AsPattern.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                ]
            )
        )
    $ do
        -- the exact #4 shape: as-pattern binds the whole value; <3-deep falls through
        it "a head as-pattern over a 3-deep cons binds the whole value (len 5)" \inst -> do
          liftEffect (callI32x1 inst "headAs" 5) >>= (_ `shouldEqual` 5)
          liftEffect (callI32x1 inst "headAs" 2) >>= (_ `shouldEqual` (-1))
        it "an as-pattern on a constructor sub-binder binds the tail (sum 10)" \inst -> do
          liftEffect (callI32x1 inst "subAs" 5) >>= (_ `shouldEqual` 10)
        it "a named scalar (literal as-pattern) binds the matched literal" \inst -> do
          liftEffect (callI32x1 inst "litAs" 0) >>= (_ `shouldEqual` 100)
          liftEffect (callI32x1 inst "litAs" 7) >>= (_ `shouldEqual` 7)
