module Test.Unit.PureScript.Backend.Wasm.CLI.Ulib.Manifest (spec) where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.CLI.Module (entryRoot)
import PureScript.Backend.Wasm.CLI.Ulib.Manifest (Manifest, lockVersion, parseLock, parseManifest, reachedMismatches, resolveModuleSet)
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

  describe "resolveModuleSet (ADR 0039 §1/§2 — presence-driven)" do
    let
      -- A reimplementation patch: the lib ships a corefn for `Data.String.CodeUnits`, whose corefn
      -- imports the non-registry internal helper `Internal.Utf8` (the registry CodeUnits does not).
      roots = [ entryRoot "Main" ]
      userImports = Map.fromFoldable
        [ Tuple "Main" [ "Data.String.CodeUnits" ]
        , Tuple "Data.String.CodeUnits" [] -- registry CodeUnits does NOT import the internal helper
        ]
      libImports = Map.fromFoldable
        [ Tuple "Data.String.CodeUnits" [ "Data.String.Internal.Utf8" ] -- the lib (reimpl) corefn does
        , Tuple "Data.String.Internal.Utf8" []
        ]

    it "a reimpl patch (lib corefn) is lib-sourced and injects its private helper" do
      let r = resolveModuleSet roots userImports libImports
      -- CodeUnits has a lib corefn → lib-sourced → its lib imports pull in the injected Internal.Utf8.
      r.libSourced `shouldEqual` Set.fromFoldable [ "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]

    it "empty libImports → nothing lib-sourced; reachable is the registry closure" do
      let
        r = resolveModuleSet roots
          (Map.fromFoldable [ Tuple "Main" [ "Data.Array" ], Tuple "Data.Array" [] ])
          Map.empty
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.Array" ]

    it "a lib module whose importer is unreached is not pulled in" do
      -- Main imports nothing → CodeUnits (hence Internal.Utf8) stays out of the closure
      let r = resolveModuleSet roots (Map.fromFoldable [ Tuple "Main" [] ]) libImports
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main" ]

    it "a wat-only patch (no lib corefn) stays user-sourced with its real imports — blocker ② regression" do
      -- `Data.Int` is a wat-only patch: the lib ships only its foreign, NO corefn, so it is absent
      -- from libImports → NOT lib-sourced. Its registry corefn (here Main→Data.Int→Data.Number) is
      -- used verbatim, so `Data.Number` (the source of `isFinite`) stays reachable and gets compiled.
      -- The pre-ADR-0039 "foreign-only" path zeroed Data.Int's imports → Data.Number was dropped.
      let
        r = resolveModuleSet roots
          ( Map.fromFoldable
              [ Tuple "Main" [ "Data.Int" ]
              , Tuple "Data.Int" [ "Data.Number" ]
              , Tuple "Data.Number" []
              ]
          )
          Map.empty
      r.libSourced `shouldEqual` (Set.empty :: Set.Set String)
      r.reachable `shouldEqual` Set.fromFoldable [ "Main", "Data.Int", "Data.Number" ]

    it "a wat-only patch and a reimpl patch coexist correctly in one build" do
      -- Data.Int (wat-only, no lib corefn) keeps its registry imports (Data.Number reached); CodeUnits
      -- (reimpl, lib corefn) is lib-sourced and injects Internal.Utf8.
      let
        r = resolveModuleSet roots
          ( Map.fromFoldable
              [ Tuple "Main" [ "Data.Int", "Data.String.CodeUnits" ]
              , Tuple "Data.Int" [ "Data.Number" ]
              , Tuple "Data.Number" []
              , Tuple "Data.String.CodeUnits" []
              ]
          )
          libImports
      r.libSourced `shouldEqual` Set.fromFoldable [ "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]
      r.reachable `shouldEqual`
        Set.fromFoldable [ "Main", "Data.Int", "Data.Number", "Data.String.CodeUnits", "Data.String.Internal.Utf8" ]
