module Test.Unit.PursWasm.CLI.Compat (spec) where

import Prelude

import Data.Either (Either(..), isLeft, isRight)
import Data.String as Str
import PursWasm.CLI.Compat (checkCorefnVersions, checkWasmBaseCompat)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- a module record shaped for `checkWasmBaseCompat`
wb :: Array String -> Array String -> { name :: Array String, foreignNames :: Array String }
wb name foreignNames = { name, foreignNames }

-- a module record shaped for `checkCorefnVersions`
cv :: Array String -> String -> { name :: Array String, builtWith :: String }
cv name builtWith = { name, builtWith }

spec :: Spec Unit
spec = describe "PursWasm.CLI.Compat" do

  describe "checkWasmBaseCompat (ADR 0026)" do
    it "accepts Wasm.* foreigns that resolve to intrinsics" do
      isRight (checkWasmBaseCompat [ wb [ "Wasm", "Array" ] [ "length", "unsafeNew" ] ])
        `shouldEqual` true

    it "rejects an unrecognised Wasm.* foreign" do
      isLeft (checkWasmBaseCompat [ wb [ "Wasm", "Array" ] [ "totallyBogusPrim" ] ])
        `shouldEqual` true

    it "ignores non-Wasm modules (their foreigns resolve elsewhere)" do
      isRight (checkWasmBaseCompat [ wb [ "Data", "Foo" ] [ "totallyBogusPrim" ] ])
        `shouldEqual` true

  describe "checkCorefnVersions (ADR 0029)" do
    it "accepts modules built with a supported purs" do
      isRight (checkCorefnVersions [ cv [ "Main" ] "0.15.16", cv [ "Lib" ] "0.15.16" ])
        `shouldEqual` true

    it "rejects a module built with an unsupported purs" do
      isLeft (checkCorefnVersions [ cv [ "Main" ] "0.15.15" ])
        `shouldEqual` true

    it "names the offending module(s) and the supported version" do
      case checkCorefnVersions [ cv [ "App", "Main" ] "0.15.15" ] of
        Left msg -> do
          Str.contains (Str.Pattern "App.Main") msg `shouldEqual` true
          Str.contains (Str.Pattern "0.15.16") msg `shouldEqual` true
        Right _ -> 1 `shouldEqual` 0
