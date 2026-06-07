-- | End-to-end guard for a **cyclic top-level value CAF** (ADR 0006). `fibAnd` is an
-- | arity-0 value (`data Fib = Fib String (Int -> Int)`) that references *itself*, so it
-- | is a value-level cycle: globalization must exclude it (it stays a getter function,
-- | recomputed per reference) rather than eager-initialise it into a global. This checks
-- | the exclusion does not break it — `fib`, which dispatches through `fibAnd`, still
-- | computes the Fibonacci numbers. (Adapted from a PureScript-Discord example.)
module Test.E2E.FibAnd (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "FibAnd (e2e): a self-referential (cyclic) top-level value CAF -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "FibAnd" ] ]
                [ "compiler/test/fixtures/FibAnd.corefn.json"
                , "compiler/test/fixtures/Data.Boolean.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                ]
            )
        )
    $ do
        it "computes Fibonacci through the self-referential CAF (fib 10 = 55)" \inst -> do
          r <- liftEffect (callI32x1 inst "fib" 10)
          r `shouldEqual` 55
        it "computes a larger value (fib 15 = 610)" \inst -> do
          r <- liftEffect (callI32x1 inst "fib" 15)
          r `shouldEqual` 610
