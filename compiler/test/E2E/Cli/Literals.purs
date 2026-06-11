-- | CLI-driven e2e (ADR 0031 phase 5) of scalar literals + literal patterns — scalar literals + literal patterns: `Int`/`Char`
-- | literal patterns with a catch-all, a `Boolean` (i31) produced + matched, an `Int -> Number -> Int`
-- | round-trip, and a `Number` literal pattern. Built standalone by the real `purs-wasm build`.
-- | (Migrated from the legacy corefn-fixture `Test.E2E.Slice4a`.)
module Test.E2E.Cli.Literals (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Literals (e2e/cli): scalar literals + literal patterns -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Literals"))
    $ do
        it "matches Int literal patterns with a catch-all" \inst -> do
          a <- liftEffect (callI32x1 inst "classify" 0)
          b <- liftEffect (callI32x1 inst "classify" 7)
          c <- liftEffect (callI32x1 inst "classify" 3)
          [ a, b, c ] `shouldEqual` [ 100, 700, 999 ]

        it "matches Char literal patterns by code point" \inst -> do
          a <- liftEffect (callI32x1 inst "classifyChar" 97)
          b <- liftEffect (callI32x1 inst "classifyChar" 122)
          c <- liftEffect (callI32x1 inst "classifyChar" 98)
          [ a, b, c ] `shouldEqual` [ 1, 26, 0 ]

        it "matches a Boolean (i31) produced by an intrinsic" \inst -> do
          a <- liftEffect (callI32x1 inst "isZero" 0)
          b <- liftEffect (callI32x1 inst "isZero" 5)
          [ a, b ] `shouldEqual` [ 10, 20 ]

        it "boxes and unboxes a Number through f64" \inst -> do
          result <- liftEffect (callI32x1 inst "roundNum" 42)
          result `shouldEqual` 42

        it "matches a Number literal pattern" \inst -> do
          a <- liftEffect (callI32x1 inst "numIsZero" 0)
          b <- liftEffect (callI32x1 inst "numIsZero" 9)
          [ a, b ] `shouldEqual` [ 1, 0 ]
