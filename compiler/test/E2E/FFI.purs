-- | End-to-end coverage of user-defined `foreign import`s (ADR 0014): a foreign
-- | resolves (via its externs) to a wasm host import satisfied at instantiation by
-- | JS. The first case is a scalar `Int -> Int`; the second exercises **String
-- | marshalling** ($Str ↔ JS string) in both directions. Whole chain: externs →
-- | resolver → host-import codegen → (marshalling) loader → run.
module Test.E2E.FFI (spec) where

import Prelude

import Data.Either (Either(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign)
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Test.E2E.Wasm (callI32x1, instantiateForeign, instantiateForeignStr)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import addOneImports :: Foreign
foreign import strImports :: Foreign
foreign import arrImports :: Foreign
foreign import recImports :: Foreign

decodeExterns :: String -> Aff (Either _ ExternsFile)
decodeExterns path = do
  buf <- liftEffect (readFile path)
  fgn <- decodeFirst buf
  pure (runDecoder decoder fgn)

spec :: Spec Unit
spec = describe "Test.E2E.FFI (user foreign import, ADR 0014)" do
  it "calls a JS Int -> Int foreign import end-to-end" do
    decodeExterns "compiler/test/fixtures/Example.FFI.externs.cbor" >>= case _ of
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

  it "marshals String foreign import args and results ($Str <-> JS string)" do
    decodeExterns "compiler/test/fixtures/Example.FFIStr.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right ef -> do
        inst <- liftEffect
          ( instantiateForeignStr [ ef ] strImports
              [ [ "Example", "FFIStr" ] ]
              [ "compiler/test/fixtures/Example.FFIStr.corefn.json" ]
          )
        -- hello _ = strLength "hello"  → String *input* marshalled → length 5
        liftEffect (callI32x1 inst "hello" 0) >>= (_ `shouldEqual` 5)
        -- shoutLen _ = strLength (shout "hi") → "HI" *output* round-trips → length 2
        liftEffect (callI32x1 inst "shoutLen" 0) >>= (_ `shouldEqual` 2)

  it "marshals Array foreign args and results ($Vals <-> JS array, recursively)" do
    decodeExterns "compiler/test/fixtures/Example.FFIArr.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right ef -> do
        inst <- liftEffect
          ( instantiateForeignStr [ ef ] arrImports
              [ [ "Example", "FFIArr" ] ]
              [ "compiler/test/fixtures/Example.FFIArr.corefn.json" ]
          )
        -- Array Int *input*: sumArr [1,2,3,4]
        liftEffect (callI32x1 inst "sumOf" 0) >>= (_ `shouldEqual` 10)
        -- Array Int *output* then input: sumArr (range 4) = 0+1+2+3
        liftEffect (callI32x1 inst "rangeSum" 4) >>= (_ `shouldEqual` 6)
        -- nested Array (Array Int): sumNested [[1,2],[3,4]]
        liftEffect (callI32x1 inst "nestedSum" 0) >>= (_ `shouldEqual` 10)
        -- Array String input: totalLen ["ab","cde"]
        liftEffect (callI32x1 inst "strsLen" 0) >>= (_ `shouldEqual` 5)

  it "marshals Record foreign args and results ($Rec <-> JS object, recursively)" do
    decodeExterns "compiler/test/fixtures/Example.FFIRec.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right ef -> do
        inst <- liftEffect
          ( instantiateForeignStr [ ef ] recImports
              [ [ "Example", "FFIRec" ] ]
              [ "compiler/test/fixtures/Example.FFIRec.corefn.json" ]
          )
        -- record *input*: descLen { name: "wasm", age: 4 } = 4 + 4 (String + Int fields)
        liftEffect (callI32x1 inst "descOf" 0) >>= (_ `shouldEqual` 8)
        -- record *output*: mkPoint n = { x: n, y: n+1 }; wasm projects the marshalled
        -- $Rec's interned labels directly
        liftEffect (callI32x1 inst "pointX" 5) >>= (_ `shouldEqual` 5)
        liftEffect (callI32x1 inst "pointY" 5) >>= (_ `shouldEqual` 6)
        liftEffect (callI32x1 inst "pointY" 0) >>= (_ `shouldEqual` 1)
