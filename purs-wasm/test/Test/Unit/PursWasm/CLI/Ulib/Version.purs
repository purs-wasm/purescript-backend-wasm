module Test.Unit.PursWasm.CLI.Ulib.Version (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import PursWasm.CLI.Ulib.Version (majorMinor, pkgVersionFromPath, splitPkgVer)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "PursWasm.CLI.Ulib.Version" do

  describe "splitPkgVer" do
    it "splits on the LAST dash (package names may contain dashes)" do
      splitPkgVer "foldable-traversable-6.0.0" `shouldEqual` { pkg: "foldable-traversable", ver: "6.0.0" }
      splitPkgVer "prelude-6.0.2" `shouldEqual` { pkg: "prelude", ver: "6.0.2" }
      splitPkgVer "arrays-7.3.0" `shouldEqual` { pkg: "arrays", ver: "7.3.0" }

  describe "majorMinor" do
    it "keeps only major.minor" do
      majorMinor "6.0.2" `shouldEqual` "6.0"
      majorMinor "7.3.0" `shouldEqual` "7.3"
      majorMinor "1.2.3.4" `shouldEqual` "1.2"

  describe "pkgVersionFromPath" do
    it "extracts the package version from a corefn modulePath" do
      pkgVersionFromPath "arrays" ".spago/p/arrays-7.3.0/src/Data/Array.purs" `shouldEqual` Just "7.3.0"
      pkgVersionFromPath "prelude" "/abs/.spago/p/prelude-6.0.2/src/Data/Functor.purs" `shouldEqual` Just "6.0.2"

    it "is Nothing when the package is not on the path" do
      pkgVersionFromPath "arrays" "output/Data.Maybe/corefn.json" `shouldEqual` Nothing
