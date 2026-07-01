-- | CLI-driven e2e of the packed numeric arrays: build / set / index / length over
-- | Wasm.I32Array / Wasm.F64Array / Wasm.I64Array, plus the zero-initialised-lane contract
-- | that distinguishes their unsafeNew from Wasm.Array.unsafeNew (a fresh lane reads 0 / 0.0,
-- | it does not trap). Built standalone by the real purs-wasm build.
module Test.E2E.Cli.PackedArrays (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Packed numeric arrays (e2e/cli): Wasm.I32Array / Wasm.F64Array / Wasm.I64Array"
    $ before (liftEffect (cliFixture "E2E.PackedArrays"))
    $ do
        it "I32Array: builds, sets, and measures length" \inst -> do
          r <- liftEffect (callI32x1 inst "i32Len" 0)
          r `shouldEqual` 3

        it "I32Array: indexes the set lanes" \inst -> do
          a <- liftEffect (callI32x1 inst "i32At" 0)
          b <- liftEffect (callI32x1 inst "i32At" 2)
          [ a, b ] `shouldEqual` [ 10, 30 ]

        it "I32Array: sums the unboxed i32 lanes" \inst -> do
          r <- liftEffect (callI32x1 inst "i32Sum" 0)
          r `shouldEqual` 60

        it "I32Array: a fresh lane is zero-initialised (no trap)" \inst -> do
          r <- liftEffect (callI32x1 inst "i32ZeroInit" 0)
          r `shouldEqual` 0

        it "F64Array: sets and multiplies unboxed f64 lanes" \inst -> do
          r <- liftEffect (callI32x1 inst "f64Mul" 0)
          r `shouldEqual` 12

        it "F64Array: measures length" \inst -> do
          r <- liftEffect (callI32x1 inst "f64Len" 0)
          r `shouldEqual` 5

        it "F64Array: a fresh lane is zero-initialised (no trap)" \inst -> do
          r <- liftEffect (callI32x1 inst "f64ZeroInit" 0)
          r `shouldEqual` 0

        it "I64Array: measures length" \inst -> do
          r <- liftEffect (callI32x1 inst "i64Len" 0)
          r `shouldEqual` 4

        it "I64Array: indexes the set i64 lanes" \inst -> do
          a <- liftEffect (callI32x1 inst "i64At" 0)
          b <- liftEffect (callI32x1 inst "i64At" 2)
          [ a, b ] `shouldEqual` [ 10, 30 ]

        it "I64Array: a fresh lane is zero-initialised (no trap)" \inst -> do
          r <- liftEffect (callI32x1 inst "i64ZeroInit" 0)
          r `shouldEqual` 0