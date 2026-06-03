-- | End-to-end coverage of a user-defined `foreign import` (ADR 0014): the
-- | `Example.FFI` fixture's `addOne :: Int -> Int` resolves (via its externs) to a
-- | wasm host import, which is satisfied at instantiation by the JS in `FFI.js`.
-- | Exercises the whole chain — externs → resolver → host-import codegen → run.
module Test.E2E.FFI (spec) where

import Prelude

import Data.Either (Either(..))
import Effect.Class (liftEffect)
import Foreign (Foreign)
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Test.E2E.Wasm (callI32x1, instantiateForeign)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import addOneImports :: Foreign

spec :: Spec Unit
spec = describe "Test.E2E.FFI (user foreign import, ADR 0014)" do
  it "calls a JS Int -> Int foreign import end-to-end" do
    buf <- liftEffect (readFile "compiler/test/fixtures/Example.FFI.externs.cbor")
    fgn <- decodeFirst buf
    case runDecoder decoder fgn :: Either _ ExternsFile of
      Left err -> fail (show err)
      Right ef -> do
        inst <- liftEffect
          ( instantiateForeign [ ef ] addOneImports
              [ [ "Example", "FFI" ] ]
              [ "compiler/test/fixtures/Example.FFI.corefn.json" ]
          )
        -- useAddOne n = addOne (addOne n); addOne is the JS `x => x + 1`
        liftEffect (callI32x1 inst "useAddOne" 5) >>= (_ `shouldEqual` 7)
        liftEffect (callI32x1 inst "useAddOne" 40) >>= (_ `shouldEqual` 42)
