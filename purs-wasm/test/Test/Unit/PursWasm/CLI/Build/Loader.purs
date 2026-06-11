-- | Unit tests for the pure loader helpers (no effects): which exports force a JS loader, and the
-- | restriction of the signature map to the entry (root) modules.
module Test.Unit.PursWasm.CLI.Build.Loader (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..))
import PursWasm.CLI.Build.Loader (exportNeedsLoader, rootExportSigs)
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
