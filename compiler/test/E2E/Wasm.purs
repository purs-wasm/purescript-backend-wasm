-- | Shared helpers for the compiler's end-to-end suites: run the full pipeline
-- | (decode a `corefn.json` fixture → lower → generate wasm → validate → emit →
-- | instantiate with the host `WebAssembly` runtime) and call exported
-- | `i32`-typed functions. Each slice's suite then only describes its fixture's
-- | expected results.
module Test.E2E.Wasm
  ( Instance
  , instantiateFixture
  , instantiateLinked
  , instantiateForeign
  , instantiateForeignStr
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
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Effect (Effect)
import Effect.Exception (error, throwException)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Codegen (buildModule)
import Data.Traversable (traverse)
import PureScript.Backend.Wasm.Externs (foreignSigs)
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, MarshalKind(..), Program)
import PureScript.Backend.Wasm.Lower (lowerModule, lowerModules)
import PureScript.Backend.Wasm.MiddleEnd (optimizeModule, optimizeProgram)
import PureScript.CoreFn (Module)
import PureScript.CoreFn.FromJSON (decodeModule)
import PureScript.ExternsFile (ExternsFile)

-- | Decode a `corefn.json` fixture, raising parse/decode failures.
decodeFixture :: String -> Effect Module
decodeFixture path = do
  source <- readFixture path
  case jsonParser source of
    Left parseErr -> throwException (error ("parse error: " <> parseErr))
    Right json -> case decodeModule json of
      Left decodeErr -> throwException (error (printJsonDecodeError decodeErr))
      Right m -> pure m

-- | Generate a Binaryen module from an IR `Program`, validate it, and instantiate
-- | the emitted wasm.
instantiateProgram :: Program -> Effect Instance
instantiateProgram program = do
  mod <- buildModule program
  ok <- B.validate mod
  when (not ok) do
    wat <- B.emitText mod
    throwException (error ("module failed validation:\n" <> wat))
  binary <- B.emitBinary mod
  B.dispose mod
  instantiate binary

-- | Decode a single fixture, lower it, and instantiate the emitted wasm.
instantiateFixture :: String -> Effect Instance
instantiateFixture path = do
  m <- decodeFixture path
  case lowerModule true (optimizeModule m) of
    Left err -> throwException (error ("lowering failed: " <> show err))
    Right program -> instantiateProgram program

-- | Decode several fixtures, **link** them into one wasm (`roots` are the modules
-- | whose functions are exported), and instantiate it (ADR 0009).
instantiateLinked :: Array (Array String) -> Array String -> Effect Instance
instantiateLinked roots paths = do
  modules <- traverse decodeFixture paths
  -- mirror the production pipeline: run the whole-program middle-end before lowering
  case lowerModules true Object.empty Object.empty roots (optimizeProgram true modules) of
    Left err -> throwException (error ("linking failed: " <> show err))
    Right program -> instantiateProgram program

-- | Link fixtures whose foreigns are resolved from `externs` (ADR 0014), and
-- | instantiate with `imports` supplying the resulting host imports (keyed by the
-- | foreign's source module, e.g. `{ "Example.FFI": { addOne } }`).
instantiateForeign :: Array ExternsFile -> Foreign -> Array (Array String) -> Array String -> Effect Instance
instantiateForeign externs imports roots paths = do
  modules <- traverse decodeFixture paths
  case lowerModules true Object.empty (foreignSigs externs) roots (optimizeProgram true modules) of
    Left err -> throwException (error ("linking failed: " <> show err))
    Right program -> do
      mod <- buildModule program
      ok <- B.validate mod
      when (not ok) do
        wat <- B.emitText mod
        throwException (error ("module failed validation:\n" <> wat))
      binary <- B.emitBinary mod
      B.dispose mod
      instantiateWith binary imports

-- | Like `instantiateForeign`, but the host imports are **String-marshalled** (ADR
-- | 0014, L2): the per-foreign marshal manifest (which params/result are `String`)
-- | is derived from the externs and handed to the JS glue, which converts `$Str`
-- | ↔ JS `string` at the boundary. `userForeigns` is the raw JS `{ Module: { fn } }`.
instantiateForeignStr :: Array ExternsFile -> Foreign -> Array (Array String) -> Array String -> Effect Instance
instantiateForeignStr externs userForeigns roots paths = do
  modules <- traverse decodeFixture paths
  let sigs = foreignSigs externs
  case lowerModules true Object.empty sigs roots (optimizeProgram true modules) of
    Left err -> throwException (error ("linking failed: " <> show err))
    Right program -> do
      mod <- buildModule program
      ok <- B.validate mod
      when (not ok) do
        wat <- B.emitText mod
        throwException (error ("module failed validation:\n" <> wat))
      binary <- B.emitBinary mod
      B.dispose mod
      instantiateMarshalled binary userForeigns (unsafeToForeign (marshalManifest sigs))

-- | The JS-shaped marshal manifest from the foreign signatures: `{ Module: { base:
-- | { params: ["string"|"raw"…], result: "string"|"raw" } } }`.
marshalManifest :: Object ForeignImport -> Object (Object { params :: Array String, result :: String })
marshalManifest = foldl add Object.empty <<< Object.values
  where
  add acc s = Object.alter
    (Just <<< Object.insert s.base { params: map kindStr s.params, result: kindStr s.result } <<< fromMaybe Object.empty)
    s.moduleName
    acc
  kindStr = case _ of
    MStr -> "string"
    _ -> "raw"

-- | A live `WebAssembly.Instance`.
foreign import data Instance :: Type

foreign import readFixture :: String -> Effect String

-- | Synchronously compile and instantiate a wasm binary (no imports).
foreign import instantiate :: Uint8Array -> Effect Instance

-- | Instantiate with the runtime plus user host imports (the foreign impls).
foreign import instantiateWith :: Uint8Array -> Foreign -> Effect Instance

-- | Instantiate with String-marshalling host imports: `instantiateMarshalled bytes
-- | userForeigns manifest` (ADR 0014, L2).
foreign import instantiateMarshalled :: Uint8Array -> Foreign -> Foreign -> Effect Instance

foreign import callI32x0 :: Instance -> String -> Effect Int
foreign import callI32x1 :: Instance -> String -> Int -> Effect Int
foreign import callI32x2 :: Instance -> String -> Int -> Int -> Effect Int
foreign import callI32x3 :: Instance -> String -> Int -> Int -> Int -> Effect Int
