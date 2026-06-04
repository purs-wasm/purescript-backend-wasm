-- | End-to-end **Effect impurification** test (ADR 0015): a *pure* `Effect`
-- | computation run via `unsafePerformEffect`. `Effect` is opaque, but operationally
-- | `Effect a ≃ Unit -> a`; the impurify pass rewrites `pureE` / `bindE` /
-- | `unsafePerformEffect` into that thunk encoding, after which the general simplifier
-- | collapses the `do`-block to plain arithmetic — `runEff n = n + 1`. This pins both
-- | that it collapses (a bare foreign `Effect.bindE` would trap at lowering) and that
-- | the result is correct.
module Test.E2E.Eff (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, callI32x2, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Effect impurification (e2e): a pure Effect do-block collapses + runs"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Eff" ] ]
                [ "compiler/test/fixtures/Eff.corefn.json"
                , "compiler/test/fixtures/Effect.corefn.json"
                , "compiler/test/fixtures/Effect.Unsafe.corefn.json"
                , "compiler/test/fixtures/Control.Applicative.corefn.json"
                , "compiler/test/fixtures/Control.Apply.corefn.json"
                , "compiler/test/fixtures/Control.Bind.corefn.json"
                , "compiler/test/fixtures/Control.Monad.corefn.json"
                , "compiler/test/fixtures/Data.Functor.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Unit.corefn.json"
                , "compiler/test/fixtures/Data.Function.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                ]
            )
        )
    $ do
        it "runs a pure Effect do-block (bind): runEff n = n + 1" \inst -> do
          r <- liftEffect (callI32x1 inst "runEff" 41)
          r `shouldEqual` 42
          r0 <- liftEffect (callI32x1 inst "runEff" 0)
          r0 `shouldEqual` 1
        -- Functor instance (functorEffect.map = liftA1 → apply + pure)
        it "runs Functor (map) over Effect: mapEff n = n + 1" \inst -> do
          r <- liftEffect (callI32x1 inst "mapEff" 9)
          r `shouldEqual` 10
        -- Apply (applyEffect.apply = ap → bind) + Applicative (pure)
        it "runs Apply/Applicative over Effect: applyEff a b = a + b" \inst -> do
          r <- liftEffect (callI32x2 inst "applyEff" 3 4)
          r `shouldEqual` 7
        -- Bind instance, explicit (>>=)
        it "runs Bind over Effect: bindEff n = n * 2" \inst -> do
          r <- liftEffect (callI32x1 inst "bindEff" 21)
          r `shouldEqual` 42
        -- a pure Effect loop (recursion through bind) must run in constant stack
        it "runs a deep Effect loop without overflowing (constant stack)" \inst -> do
          r <- liftEffect (callI32x1 inst "countEff" 1000000)
          r `shouldEqual` 1000000
