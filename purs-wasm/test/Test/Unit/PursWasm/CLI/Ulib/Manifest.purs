module Test.Unit.PursWasm.CLI.Ulib.Manifest (spec) where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PursWasm.CLI.Ulib.Manifest (Manifest, lockVersion, parseLock, parseManifest, reachedMismatches)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- A two-package manifest used across the reachedMismatches cases.
fixture :: Manifest
fixture = Map.fromFoldable
  [ Tuple "prelude" { version: "6.0.2", modules: [ "Data.Show", "Data.Ord" ] }
  , Tuple "arrays" { version: "7.3.0", modules: [ "Data.Array" ] }
  ]

spec :: Spec Unit
spec = describe "PursWasm.CLI.Ulib.Manifest" do

  describe "parseManifest" do
    it "parses package -> { version, modules }" do
      parseManifest """{ "prelude": { "version": "6.0.2", "modules": ["Data.Show", "Data.Ord"] } }"""
        `shouldEqual` Just (Map.fromFoldable [ Tuple "prelude" { version: "6.0.2", modules: [ "Data.Show", "Data.Ord" ] } ])

    it "is Nothing on malformed JSON or a missing field" do
      parseManifest "{ not json" `shouldEqual` (Nothing :: Maybe Manifest)
      parseManifest """{ "prelude": { "modules": ["Data.Show"] } }""" `shouldEqual` (Nothing :: Maybe Manifest)

  describe "parseLock / lockVersion" do
    let
      lock = parseLock
        """{ "workspace": { "package_set": { "content": { "prelude": "6.0.2" } } },
             "packages": { "arrays": { "version": "7.3.0" } } }"""
    it "reads a package-set content override" do
      lockVersion lock "prelude" `shouldEqual` Just "6.0.2"
    it "falls back to packages.<pkg>.version" do
      lockVersion lock "arrays" `shouldEqual` Just "7.3.0"
    it "is Nothing for an unknown package" do
      lockVersion lock "strings" `shouldEqual` Nothing

  describe "reachedMismatches" do
    let
      lock = parseLock
        """{ "packages": { "prelude": { "version": "6.0.99" }, "arrays": { "version": "7.3.0" } } }"""
    it "reports a reached package whose version differs (exact match)" do
      -- prelude reached (Data.Show) at 6.0.99 ≠ supported 6.0.2 → one mismatch; arrays matches
      reachedMismatches fixture lock (Set.fromFoldable [ "Data.Show", "Data.Array" ])
        `shouldEqual` [ { package: "prelude", want: "6.0.2", got: Just "6.0.99" } ]

    it "ignores an unused package even if its version differs (pay for what you use)" do
      -- only Data.Array reached; prelude's mismatch must NOT be reported
      reachedMismatches fixture lock (Set.fromFoldable [ "Data.Array" ]) `shouldEqual` []

    it "reports at most once per package (not once per reached module)" do
      reachedMismatches fixture lock (Set.fromFoldable [ "Data.Show", "Data.Ord" ])
        `shouldEqual` [ { package: "prelude", want: "6.0.2", got: Just "6.0.99" } ]

    it "reports got = Nothing when the package is absent from the lock" do
      let empty = parseLock """{ "packages": {} }"""
      reachedMismatches fixture empty (Set.fromFoldable [ "Data.Show" ])
        `shouldEqual` [ { package: "prelude", want: "6.0.2", got: Nothing } ]

    it "is empty when every reached package matches" do
      let matching = parseLock """{ "packages": { "prelude": { "version": "6.0.2" }, "arrays": { "version": "7.3.0" } } }"""
      reachedMismatches fixture matching (Set.fromFoldable [ "Data.Show", "Data.Array" ]) `shouldEqual` []
