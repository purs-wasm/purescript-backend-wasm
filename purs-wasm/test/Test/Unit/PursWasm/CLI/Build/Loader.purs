-- | Unit tests for the pure loader helpers (no effects): which exports force a JS loader, and the
-- | restriction of the signature map to the entry (root) modules.
module Test.Unit.PursWasm.CLI.Build.Loader (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..))
import PursWasm.CLI.Build.Loader (exportNeedsLoader, loaderSource, rootExportSigs)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

sig :: String -> String -> Array MarshalKind -> MarshalKind -> { moduleName :: String, base :: String, params :: Array MarshalKind, result :: MarshalKind }
sig moduleName base params result = { moduleName, base, params, result }

spec :: Spec Unit
spec = describe "PursWasm.CLI.Build.Loader" do

  describe "exportNeedsLoader" do
    it "is false for all-raw (i32/f64) signatures" do
      exportNeedsLoader (sig "M" "f" [ MI32, MF64 ] MI32) `shouldEqual` false

    it "is true when a parameter is non-raw (needs marshalling)" do
      exportNeedsLoader (sig "M" "g" [ MStr ] MI32) `shouldEqual` true

    it "is true when the result is non-raw" do
      exportNeedsLoader (sig "M" "h" [ MI32 ] (MArray MI32)) `shouldEqual` true

  describe "rootExportSigs" do
    it "keeps only the entry modules' signatures, keyed by bare name" do
      let
        sigs = Object.fromFoldable
          [ Tuple "M.f" (sig "M" "f" [] MI32)
          , Tuple "N.g" (sig "N" "g" [] MI32)
          ]
        kept = rootExportSigs [ [ "M" ] ] sigs
      Object.lookup "f" kept `shouldEqual` Just (sig "M" "f" [] MI32)
      Object.lookup "g" kept `shouldEqual` Nothing

  -- The browser target has no CI runtime, so guard its loader prologue here: node and browser share
  -- the marshalling body but differ in how the wasm bytes are loaded (`-p browser`, ADR 0025).
  describe "loaderSource (node vs browser wasm load)" do
    let
      has s src = contains (Pattern s) src
      node = loaderSource false false "{}" "{}"
      browser = loaderSource true false "{}" "{}"
    it "node reads the wasm off disk via node:fs" do
      has "node:fs" node `shouldEqual` true
      has "readFileSync(fileURLToPath" node `shouldEqual` true
      has "WebAssembly.compileStreaming" node `shouldEqual` false
    it "browser fetches + compileStreams the wasm and uses no node APIs" do
      has "WebAssembly.compileStreaming(fetch(" browser `shouldEqual` true
      has "node:fs" browser `shouldEqual` false
      has "fileURLToPath" browser `shouldEqual` false
    it "both share the marshalling glue and export wiring" do
      has "makeMarshal" browser `shouldEqual` true
      has "export default exports;" browser `shouldEqual` true
      has "export default exports;" node `shouldEqual` true

    it "appends a `main()` call only with --executable (-E)" do
      has "exports.main();" (loaderSource false true "{}" "{}") `shouldEqual` true
      has "exports.main();" (loaderSource true true "{}" "{}") `shouldEqual` true
      has "exports.main();" node `shouldEqual` false
