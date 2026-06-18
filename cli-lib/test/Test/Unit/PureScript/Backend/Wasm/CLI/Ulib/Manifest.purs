module Test.Unit.PureScript.Backend.Wasm.CLI.Ulib.Manifest (spec) where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Ulib.Manifest (Manifest, lockVersion, parseLock, parseManifest, reachedMismatches, resolveModuleSet, shadowSet)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- A two-package manifest used across the reachedMismatches cases.
fixture :: Manifest
fixture = Map.fromFoldable
  [ Tuple "prelude" { version: "6.0.2", modules: [ "Data.Show", "Data.Ord" ] }
  , Tuple "arrays" { version: "7.3.0", modules: [ "Data.Array" ] }
  ]

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.CLI.Ulib.Manifest" do

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

  describe "shadowSet" do
    let
      lock = parseLock """{ "packages": { "prelude": { "version": "6.0.2" }, "arrays": { "version": "7.3.0" } } }"""
    it "includes a covered module that is reached and version-matched" do
      shadowSet fixture lock (Set.fromFoldable [ "Data.Show", "Data.Array" ])
        `shouldEqual` Set.fromFoldable [ "Data.Show", "Data.Array" ]
    it "includes only the reached modules of a matched package" do
      shadowSet fixture lock (Set.fromFoldable [ "Data.Show" ]) `shouldEqual` Set.fromFoldable [ "Data.Show" ]
    it "excludes a package whose version differs, even when reached (exact match)" do
      let drifted = parseLock """{ "packages": { "prelude": { "version": "6.0.99" }, "arrays": { "version": "7.3.0" } } }"""
      shadowSet fixture drifted (Set.fromFoldable [ "Data.Show", "Data.Array" ]) `shouldEqual` Set.fromFoldable [ "Data.Array" ]
    it "is empty when nothing is reached" do
      shadowSet fixture lock Set.empty `shouldEqual` (Set.empty :: Set.Set String)

  describe "resolveModuleSet (ADR 0031 §6)" do
    let
      -- strings 6.0.1 covers the registry module CodeUnits; the lib's CodeUnits corefn imports the
      -- non-registry internal helper `Internal.Utf8`.
      strManifest = Map.fromFoldable [ Tuple "strings" { version: "6.0.1", modules: [ "Data.String.CodeUnits" ] } ]
      matchLock = parseLock """{ "packages": { "strings": { "version": "6.0.1" } } }"""
      roots = [ entryRoot "Main" ]
      userMods = Set.fromFoldable [ "Main", "Data.String.CodeUnits" ]
      userImports = Map.fromFoldable
        [ Tuple "Main" [ "Data.String.CodeUnits" ]
        , Tuple "Data.String.CodeUnits" [] -- registry CodeUnits does NOT import the internal helper
        ]
      libImports = Map.fromFoldable
        [ Tuple "Data.String.CodeUnits" [ "Data.String.Internal.Utf8" ] -- the lib corefn does
        , Tuple "Data.String.Internal.Utf8" []
        ]

    it "no manifest → nothing lib-sourced; reachable is the registry closure" do
      let r = resolveModuleSet roots userMods userImports libImports Nothing Nothing
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.String.CodeUnits" ]

    it "shadowed + version match → injects the private helper reached only via the lib corefn" do
      let r = resolveModuleSet roots userMods userImports libImports (Just strManifest) (Just matchLock)
      -- CodeUnits is shadowed; Internal.Utf8 is injected (not a user module, reached via lib imports)
      r.libSourced `shouldEqual` Set.fromFoldable [ "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]

    it "version mismatch → not shadowed, so the internal helper is never reached" do
      let drift = parseLock """{ "packages": { "strings": { "version": "6.0.99" } } }"""
      let r = resolveModuleSet roots userMods userImports libImports (Just strManifest) (Just drift)
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.String.CodeUnits" ]

    it "an internal helper whose importer is unreached is not pulled in" do
      -- Main imports nothing → CodeUnits (hence Internal.Utf8) stays out of the closure
      let r = resolveModuleSet roots userMods (Map.fromFoldable [ Tuple "Main" [] ]) libImports (Just strManifest) (Just matchLock)
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main" ]

    it "a foreign-only covered module (no lib corefn) is lib-sourced via shadowing, not injection" do
      -- integers covers Data.Int but the lib has no corefn for it (foreign-only) → absent from libImports
      let intManifest = Map.fromFoldable [ Tuple "integers" { version: "6.0.0", modules: [ "Data.Int" ] } ]
      let intLock = parseLock """{ "packages": { "integers": { "version": "6.0.0" } } }"""
      let
        r = resolveModuleSet [ entryRoot "Main" ] (Set.fromFoldable [ "Main", "Data.Int" ])
          (Map.fromFoldable [ Tuple "Main" [ "Data.Int" ], Tuple "Data.Int" [] ])
          Map.empty
          (Just intManifest)
          (Just intLock)
      -- Data.Int is in libSourced (covered + reached + matched), so the caller will *try* the lib
      -- corefn and fall back to the registry one; nothing is injected.
      r.libSourced `shouldEqual` Set.fromFoldable [ "Data.Int" ]
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.Int" ]
