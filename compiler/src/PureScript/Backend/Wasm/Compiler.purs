-- | The public build facade: parse `corefn.json` sources and link a set of
-- | modules into one wasm binary (ADR 0009). This keeps the CLI (`bin`) free of
-- | the Argonaut / Binaryen / IR details — it only does file I/O and calls these.
module PureScript.Backend.Wasm.Compiler
  ( CompileOptions
  , parseModule
  , compileModules
  , compileModulesText
  ) where

import Prelude

import Binaryen as B
import Data.Argonaut.Decode (printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Effect (Effect)
import PureScript.Backend.Wasm.Codegen (buildModule)
import PureScript.Backend.Wasm.Externs (ctorFieldReps, foreignSigs)
import PureScript.Backend.Wasm.Intrinsics (effectfulForeignNames)
import PureScript.Backend.Wasm.Lower (lowerModules)
import PureScript.Backend.Wasm.MiddleEnd (optimizeProgram)
import PureScript.CoreFn (Module, ModuleName)
import PureScript.CoreFn.FromJSON (decodeModule)
import PureScript.ExternsFile (ExternsFile)

-- | Parse a `corefn.json` source string into a `Module`, with failures rendered
-- | as a message.
parseModule :: String -> Either String Module
parseModule source = case jsonParser source of
  Left parseErr -> Left ("corefn parse error: " <> parseErr)
  Right json -> case decodeModule json of
    Left decodeErr -> Left ("corefn decode error: " <> printJsonDecodeError decodeErr)
    Right m -> Right m

-- | Build options. `optimize` runs Binaryen's optimizer (which also DCE-drops the
-- | non-root functions); turning it off (a debug build) keeps the wasm closer to
-- | the emitted IR — and is where source-map support will hang once CoreFn source
-- | spans are threaded through to Binaryen debug locations. `optimizeMir` toggles
-- | the middle-end (dictionary elimination); off builds an unoptimized baseline
-- | (lambda lifting still runs, since it is needed for constant-stack tail recursion).
type CompileOptions = { optimize :: Boolean, optimizeMir :: Boolean }

-- | Link the given modules into one validated wasm and run `emit` on it (e.g.
-- | `emitBinary` or `emitText`). `roots` are the entry modules whose functions
-- | stay exported; everything else is internal and so removed by the optimizer's
-- | DCE (ADR 0009). Linking or validation failures come back as a message.
withCompiledModule
  :: forall a
   . CompileOptions
  -> (B.Module -> Effect a)
  -> Array ModuleName
  -> Array Module
  -> Array ExternsFile
  -> Effect (Either String a)
withCompiledModule opts emit roots modules externs = case lowerModules opts.optimizeMir (ctorFieldReps externs) (foreignSigs externs) roots (optimizeProgram opts.optimizeMir effectfulForeignNames modules) of
  Left err -> pure (Left ("linking failed: " <> show err))
  Right program -> do
    mod <- buildModule program
    when opts.optimize (B.optimize mod)
    ok <- B.validate mod
    if not ok then do
      wat <- B.emitText mod
      B.dispose mod
      pure (Left ("emitted module failed validation:\n" <> wat))
    else do
      result <- emit mod
      B.dispose mod
      pure (Right result)

-- | Link the given modules into one wasm and return its binary bytes. `externs`
-- | supplies type information for type-directed lowering (front B); pass `[]` to
-- | build without it (everything stays boxed).
compileModules :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Effect (Either String Uint8Array)
compileModules opts = withCompiledModule opts B.emitBinary

-- | Link the given modules into one wasm and return its WAT (text) form.
compileModulesText :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Effect (Either String String)
compileModulesText opts = withCompiledModule opts B.emitText
