-- | CLI-driven e2e (ADR 0031 phase 5) of the `Array` instances: `map`/`<$>` (incl. empty), `<*>`
-- | (apply), and bind (flatMap, incl. an empty result) — exercising the ulib `Data.Functor`/
-- | `Control.Apply`/`Control.Bind` shadows through the real `purs-wasm build`. (Migrated from the
-- | legacy corefn-fixture `Test.E2E.PreludeFunctor`.)
module Test.E2E.Cli.PreludeFunctor (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Array Functor/Apply/Bind (e2e/cli): map <*> >>= -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Fab"))
    $ do
        it "maps over an Array (map and <$>, incl. empty)" \inst -> do
          m <- liftEffect (callI32x0 inst "mapOk")
          fm <- liftEffect (callI32x0 inst "fmapOk")
          e <- liftEffect (callI32x0 inst "mapEmpty")
          [ m, fm, e ] `shouldEqual` [ 1, 1, 1 ]

        it "applies an Array of functions ((+) <$> [1,2] <*> [10,20])" \inst -> do
          a <- liftEffect (callI32x0 inst "applyOk")
          a `shouldEqual` 1

        it "binds (flatMap) an Array (incl. an empty result)" \inst -> do
          b <- liftEffect (callI32x0 inst "bindOk")
          e <- liftEffect (callI32x0 inst "bindEmpty")
          [ b, e ] `shouldEqual` [ 1, 1 ]
