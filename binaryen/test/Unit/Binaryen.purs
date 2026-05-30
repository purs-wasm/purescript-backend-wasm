module Test.Unit.Binaryen where

import Prelude

import Binaryen as B
import Data.ArrayBuffer.Types (Uint8Array)
import Data.String (Pattern(..))
import Data.String as String
import Effect (Effect)
import Effect.Class (liftEffect)
import Test.Fixtures (buildAddInto, withModule)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

spec :: Spec Unit
spec = describe "Binaryen (unit)" do
  describe "module lifecycle" do
    it "validates a freshly created empty module" do
      ok <- liftEffect $ withModule B.validate
      ok `shouldEqual` true

  describe "function building" do
    it "builds a valid add(i32, i32) -> i32 function" do
      { ok } <- liftEffect buildAdd
      ok `shouldEqual` true

    it "emits WAT with the expected signature and body" do
      { wat } <- liftEffect buildAdd
      -- the function and its (i32, i32) -> i32 signature
      wat `shouldSatisfy` String.contains (Pattern "(func $add")
      wat `shouldSatisfy` String.contains (Pattern "(param $0 i32) (param $1 i32)")
      wat `shouldSatisfy` String.contains (Pattern "(result i32)")
      -- the body built from localGet + i32Add
      wat `shouldSatisfy` String.contains (Pattern "i32.add")
      wat `shouldSatisfy` String.contains (Pattern "local.get $0")
      wat `shouldSatisfy` String.contains (Pattern "local.get $1")

    it "exports the function under its external name" do
      { wat } <- liftEffect buildAdd
      wat `shouldSatisfy` String.contains (Pattern "(export \"add\" (func $add))")

  describe "expressions" do
    it "builds a valid module returning an i32 constant" do
      ok <- liftEffect $ withModule \mod -> do
        body <- B.i32Const mod 42
        _ <- B.addFunction mod "answer" B.none B.i32 [] body
        B.validate mod
      ok `shouldEqual` true

  describe "emission" do
    it "wraps emitText output in a (module ...) form" do
      wat <- liftEffect $ withModule B.emitText
      wat `shouldSatisfy` String.contains (Pattern "(module")

    it "emits a binary starting with the wasm magic bytes" do
      bytes <- liftEffect $ withModule \mod -> do
        buildAddInto mod
        B.emitBinary mod
      -- "\0asm" magic + version word = an 8-byte header at minimum
      byteLength bytes `shouldSatisfy` (_ >= 8)
      magicPrefix bytes `shouldEqual` [ 0x00, 0x61, 0x73, 0x6d ]

-- | Build the `add` module and return whether it validates plus its WAT.
buildAdd :: Effect { ok :: Boolean, wat :: String }
buildAdd = withModule \mod -> do
  buildAddInto mod
  ok <- B.validate mod
  wat <- B.emitText mod
  pure { ok, wat }

-- | Byte length of an emitted wasm binary.
foreign import byteLength :: Uint8Array -> Int

-- | The first four bytes of an emitted wasm binary, as ints.
foreign import magicPrefix :: Uint8Array -> Array Int

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] spec