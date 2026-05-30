-- | End-to-end test: build a module with the Binaryen FFI, emit it to a wasm
-- | binary, instantiate it with the host's `WebAssembly` runtime (Node's, here)
-- | and execute the exported function — proving the whole pipeline produces wasm
-- | that actually runs and computes the right answer.
module Test.E2E.Binaryen where

import Prelude

import Binaryen as B
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Class (liftEffect)
import Test.Fixtures (buildAddInto, withModule)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

spec :: Spec Unit
spec = describe "Binaryen (e2e)"
  $ before (liftEffect (buildAddBinary >>= instantiate))
  $
    describe "the emitted add(i32, i32) -> i32 module" do
      it "computes a + b for ordinary inputs" \inst ->
        for_ cases \{ a, b } -> do
          result <- liftEffect $ callI32x2 inst "add" a b
          result `shouldEqual` (a + b)

      it "wraps on i32 overflow, matching PureScript Int semantics" \inst -> do
        -- maxInt + 1 wraps to minInt in both wasm i32 and PureScript Int
        result <- liftEffect $ callI32x2 inst "add" maxI32 1
        result `shouldEqual` (maxI32 + 1)

-- | Inputs exercised against the running module. Includes negatives, which
-- | round-trip through wasm i32 as two's-complement.
cases :: Array { a :: Int, b :: Int }
cases =
  [ { a: 0, b: 0 }
  , { a: 1, b: 2 }
  , { a: 19, b: 23 }
  , { a: -5, b: 8 }
  , { a: -100, b: -28 }
  ]

-- | The largest i32 (2147483647); spelled out to avoid pulling in Data.Int
-- | (whose `top` would also shadow Prelude) just for the bound.
maxI32 :: Int
maxI32 = 2147483647

-- | Build the `add` module and emit it as a wasm binary.
buildAddBinary :: Effect Uint8Array
buildAddBinary = withModule \mod -> do
  buildAddInto mod
  B.emitBinary mod

-- | A live `WebAssembly.Instance`.
foreign import data Instance :: Type

-- | Synchronously compile and instantiate a wasm binary (no imports).
foreign import instantiate :: Uint8Array -> Effect Instance

-- | Call an exported `(i32, i32) -> i32` function by name.
foreign import callI32x2 :: Instance -> String -> Int -> Int -> Effect Int

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] spec