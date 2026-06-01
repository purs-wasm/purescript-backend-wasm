-- | End-to-end test of Slice 4a (scalar literals + literal-pattern matching):
-- | `Int`/`Char` literal patterns, `Boolean` as `i31` (produced internally and
-- | matched by `if`), `Number` as `(struct f64)` (round-tripped and matched with
-- | `f64.eq`). All entry points are `i32 -> i32` so they run through the host.
module Test.E2E.Slice4a (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Slice 4a (e2e): scalar literals + literal patterns -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Slice4a.corefn.json"))
    $ do
        -- classify n = case n of 0 -> 100; 7 -> 700; _ -> 999
        it "matches Int literal patterns with a catch-all" \inst -> do
          a <- liftEffect (callI32x1 inst "classify" 0)
          b <- liftEffect (callI32x1 inst "classify" 7)
          c <- liftEffect (callI32x1 inst "classify" 3)
          [ a, b, c ] `shouldEqual` [ 100, 700, 999 ]

        -- classifyChar c = case c of 'a' -> 1; 'z' -> 26; _ -> 0  (Char = Int rep)
        it "matches Char literal patterns by code point" \inst -> do
          a <- liftEffect (callI32x1 inst "classifyChar" 97)
          b <- liftEffect (callI32x1 inst "classifyChar" 122)
          c <- liftEffect (callI32x1 inst "classifyChar" 98)
          [ a, b, c ] `shouldEqual` [ 1, 26, 0 ]

        -- isZero n = if eqI n 0 then 10 else 20  (Boolean i31, produced + matched)
        it "matches a Boolean (i31) produced by an intrinsic" \inst -> do
          a <- liftEffect (callI32x1 inst "isZero" 0)
          b <- liftEffect (callI32x1 inst "isZero" 5)
          [ a, b ] `shouldEqual` [ 10, 20 ]

        -- roundNum n = numToInt (intToNum n)  (Int -> Number -> Int round trip)
        it "boxes and unboxes a Number through f64" \inst -> do
          result <- liftEffect (callI32x1 inst "roundNum" 42)
          result `shouldEqual` 42

        -- numIsZero n = case intToNum n of 0.0 -> 1; _ -> 0  (Number literal, f64.eq)
        it "matches a Number literal pattern" \inst -> do
          a <- liftEffect (callI32x1 inst "numIsZero" 0)
          b <- liftEffect (callI32x1 inst "numIsZero" 9)
          [ a, b ] `shouldEqual` [ 1, 0 ]
