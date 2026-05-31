-- | Shared helpers for the compiler's end-to-end suites: run the full pipeline
-- | (decode a `corefn.json` fixture → lower → generate wasm → validate → emit →
-- | instantiate with the host `WebAssembly` runtime) and call exported
-- | `i32`-typed functions. Each slice's suite then only describes its fixture's
-- | expected results.
module Test.E2E.Wasm
  ( Instance
  , instantiateFixture
  , callI32x0
  , callI32x1
  , callI32x2
  , callI32x3
  ) where

import Prelude

import Binaryen as B
import Data.Argonaut.Decode (printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Codegen (buildModule)
import PureScript.Backend.Wasm.Lower (lowerModule)
import PureScript.CoreFn.FromJSON (decodeModule)

-- | Decode the fixture, lower it to IR, generate a Binaryen module, and
-- | instantiate the emitted wasm. Any failure (parse / decode / lowering /
-- | validation) is raised with a useful message.
instantiateFixture :: String -> Effect Instance
instantiateFixture path = do
  source <- readFixture path
  m <- case jsonParser source of
    Left parseErr -> throwException (error ("parse error: " <> parseErr))
    Right json -> case decodeModule json of
      Left decodeErr -> throwException (error (printJsonDecodeError decodeErr))
      Right m -> pure m
  program <- case lowerModule m of
    Left err -> throwException (error ("lowering failed: " <> show err))
    Right program -> pure program
  mod <- buildModule program
  ok <- B.validate mod
  when (not ok) do
    wat <- B.emitText mod
    throwException (error ("module failed validation:\n" <> wat))
  binary <- B.emitBinary mod
  B.dispose mod
  instantiate binary

-- | A live `WebAssembly.Instance`.
foreign import data Instance :: Type

foreign import readFixture :: String -> Effect String

-- | Synchronously compile and instantiate a wasm binary (no imports).
foreign import instantiate :: Uint8Array -> Effect Instance

foreign import callI32x0 :: Instance -> String -> Effect Int
foreign import callI32x1 :: Instance -> String -> Int -> Effect Int
foreign import callI32x2 :: Instance -> String -> Int -> Int -> Effect Int
foreign import callI32x3 :: Instance -> String -> Int -> Int -> Int -> Effect Int
