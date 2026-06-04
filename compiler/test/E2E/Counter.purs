-- | End-to-end test that the middle-end's **purity analysis** preserves effect
-- | semantics (ADR 0015). `Counter` uses two genuinely effectful primitives backed by a
-- | mutable wasm global (`incrCtr` / `readCtr`); a purity-blind optimizer would drop the
-- | result-unused `incrCtr`s as dead `let`s (count lost) or reorder the interleaved
-- | reads (order lost). With the guards, each effect runs exactly once, in order.
module Test.E2E.Counter (spec) where

import Prelude

import Effect (Effect)
import Effect.Class (liftEffect)
import Test.E2E.Wasm (Instance, callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

linked :: Effect Instance
linked =
  instantiateLinked [ [ "Counter" ] ]
    [ "compiler/test/fixtures/Counter.corefn.json"
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
    ]

spec :: Spec Unit
spec = describe "Effect purity (e2e): effectful runs are preserved (ADR 0015)" do
  -- COUNT: each call performs exactly three increments. A purity-blind optimizer drops
  -- the result-unused `incrCtr`s and every call would read 0. Repeated calls on one
  -- instance read 3, 6, 9 — proving exactly three effects ran per call (not 0, not 1).
  before (liftEffect linked) $
    it "preserves effect count (three incrs per call: 3, 6, 9)" \inst -> do
      r1 <- liftEffect (callI32x1 inst "countThree" 0)
      r1 `shouldEqual` 3
      r2 <- liftEffect (callI32x1 inst "countThree" 0)
      r2 `shouldEqual` 6
      r3 <- liftEffect (callI32x1 inst "countThree" 0)
      r3 `shouldEqual` 9
  -- ORDER: on a fresh counter, incr→1, x=1, incr→2, y=2 ⇒ x*10 + y = 12. A reordered
  -- or duplicated read would yield a different number.
  before (liftEffect linked) $
    it "preserves effect order (interleaved reads ⇒ 12)" \inst -> do
      r <- liftEffect (callI32x1 inst "order" 0)
      r `shouldEqual` 12
