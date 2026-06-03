-- | End-to-end **stack-safety** test: a `State`-monad loop run for far more
-- | iterations than any call stack could hold. It completes in constant stack *only*
-- | because the monad collapses to a tail loop — newtype transparency, the simplifier
-- | reductions (multi-scrutinee `case`, capture-avoiding substitution, record
-- | scalarization, commuting conversion, lambda merge) and tail-call elimination all
-- | have to fire. If any of them regresses, the recursion rebuilds an O(n) stack and
-- | this overflows — so the test fails loudly. Unlike a value-only check, this guards
-- | that the *optimization happened*, which a semantics-preserving regression would
-- | otherwise pass silently (ADR 0015).
module Test.E2E.StackSafe (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Stack safety (e2e): a deep State-monad loop must run in constant stack"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "StackSafe" ] ]
                [ "compiler/test/fixtures/StackSafe.corefn.json"
                , "compiler/test/fixtures/Data.Functor.corefn.json"
                , "compiler/test/fixtures/Control.Apply.corefn.json"
                , "compiler/test/fixtures/Control.Applicative.corefn.json"
                , "compiler/test/fixtures/Control.Bind.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                ]
            )
        )
    $ do
        -- `countTo n` counts the State from 0 to n and returns n; running it for a
        -- million iterations would blow any stack unless the loop is collapsed + TCE'd.
        it "runs a million State iterations without overflowing" \inst -> do
          r <- liftEffect (callI32x1 inst "countTo" 1000000)
          r `shouldEqual` 1000000
        it "is correct for a small count too" \inst -> do
          r <- liftEffect (callI32x1 inst "countTo" 42)
          r `shouldEqual` 42
