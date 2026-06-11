module Test.Unit.PursWasm.CLI.Ulib.Version (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import PursWasm.CLI.Ulib.Version (compareVersion, majorMinor, pkgVersionFromPath, splitPkgVer)
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

  describe "compareVersion" do
    it "compares numerically, not lexicographically" do
      compareVersion "0.15.9" "0.15.10" `shouldEqual` LT
      compareVersion "0.15.10" "0.15.9" `shouldEqual` GT
      compareVersion "0.15.16" "0.15.15" `shouldEqual` GT

    it "is EQ for equal versions and treats missing components as 0" do
      compareVersion "1.0.0" "1.0.0" `shouldEqual` EQ
      compareVersion "1" "1.0.0" `shouldEqual` EQ
      compareVersion "1.2" "1.2.0" `shouldEqual` EQ

    it "compares major and minor before patch, over the first three components only" do
      compareVersion "2.0.0" "1.9.9" `shouldEqual` GT
      compareVersion "1.2.3" "1.3.0" `shouldEqual` LT
      compareVersion "1.2.3.4" "1.2.3.99" `shouldEqual` EQ
