-- | Unit tests for the pure decision logic of `ulib compat` (ADR 0029): constraint membership,
-- | the supported-compiler intersection, the purs-pin guard, the shadow classification, and the
-- | byte-exact compat.json serializer (which the differential test relies on for parity). The IO
-- | orchestration is covered by the differential harness.
module Test.Unit.UlibTooling.Compat (spec) where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as Str
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.CLI.Effect.Registry (RegistryF(..))
import PureScript.Backend.Wasm.CLI.Effect.Registry as Registry
import UlibTooling.Compat (CheckRow(..), classifyShadow, pursGuard, querySupported, supportedRange, withinConstraint)
import UlibTooling.Compat.Types (encodeCompat, readCompatCore)
import Run (Run, extract)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)
import Type.Row (type (+))

-- The committed compat.json, byte-for-byte (the regenerate parity target).
committedCompat :: String
committedCompat =
  "{\n\
  \  \"packageSet\": \"77.4.0\",\n\
  \  \"pursPin\": \"0.15.16\",\n\
  \  \"pursMin\": \"0.15.15\",\n\
  \  \"pursMax\": \"0.15.16\",\n\
  \  \"packages\": {\n\
  \    \"arrays\": \"7.3.0\",\n\
  \    \"foldable-traversable\": \"6.0.0\",\n\
  \    \"prelude\": \"6.0.2\"\n\
  \  }\n\
  \}\n"

spec :: Spec Unit
spec = describe "UlibTooling.Compat" do

  describe "withinConstraint" do
    it "admits everything when there is no constraint" do
      withinConstraint Nothing "0.0.1" `shouldEqual` true
    it "respects an inclusive lower and exclusive upper bound" do
      let c = Just ">=0.15.15 <0.16.0"
      withinConstraint c "0.15.15" `shouldEqual` true -- lower is inclusive
      withinConstraint c "0.15.16" `shouldEqual` true
      withinConstraint c "0.15.14" `shouldEqual` false -- below
      withinConstraint c "0.16.0" `shouldEqual` false -- upper is exclusive
    it "handles a one-sided constraint" do
      withinConstraint (Just ">=0.15.0") "0.20.0" `shouldEqual` true
      withinConstraint (Just "<0.16.0") "0.15.0" `shouldEqual` true
      withinConstraint (Just "<0.16.0") "0.16.1" `shouldEqual` false

  describe "supportedRange" do
    it "intersects the per-package compiler lists, numerically sorted" do
      supportedRange Nothing [ [ "0.15.0", "0.15.1", "0.15.2" ], [ "0.15.1", "0.15.2", "0.15.3" ] ]
        `shouldEqual` [ "0.15.1", "0.15.2" ]
    it "sorts numerically, not lexicographically" do
      supportedRange Nothing [ [ "0.15.10", "0.15.9", "0.15.2" ] ]
        `shouldEqual` [ "0.15.2", "0.15.9", "0.15.10" ]
    it "filters the intersection to the package-set constraint" do
      supportedRange (Just ">=0.15.2 <0.16.0") [ [ "0.15.1", "0.15.2", "0.15.3" ] ]
        `shouldEqual` [ "0.15.2", "0.15.3" ]
    it "is empty when there are no packages" do
      supportedRange Nothing [] `shouldEqual` []
    it "is empty when the intersection is empty" do
      supportedRange Nothing [ [ "0.15.0" ], [ "0.15.1" ] ] `shouldEqual` []

  describe "pursGuard" do
    it "accepts a pin that is a member, returning the bounds" do
      pursGuard "0.15.16" [ "0.15.15", "0.15.16" ] `shouldEqual` Right { min: "0.15.15", max: "0.15.16" }
    it "rejects an empty range" do
      pursGuard "0.15.16" [] `shouldSatisfy` isLeft
    it "diagnoses a pin below the supported min as too old" do
      pursGuard "0.15.14" [ "0.15.15", "0.15.16" ] `shouldSatisfy` leftContains "too old"
    it "diagnoses a pin above the supported max as too new" do
      pursGuard "0.15.17" [ "0.15.15", "0.15.16" ] `shouldSatisfy` leftContains "too new"
    it "diagnoses a pin inside the bounds but absent as a gap" do
      pursGuard "0.15.16" [ "0.15.15", "0.15.17" ] `shouldSatisfy` leftContains "a gap"

  describe "classifyShadow" do
    it "is Unresolved when the package set does not resolve the package" do
      classifyShadow "6.0.0" Nothing `shouldEqual` Unresolved
    it "is Stale on a major.minor divergence" do
      classifyShadow "6.0.0" (Just "5.0.0") `shouldEqual` Stale "5.0.0"
      classifyShadow "6.0.0" (Just "6.1.0") `shouldEqual` Stale "6.1.0"
    it "is Drift on a patch-only divergence" do
      classifyShadow "6.0.0" (Just "6.0.2") `shouldEqual` Drift "6.0.2"
    it "is Match on an exact version" do
      classifyShadow "6.0.0" (Just "6.0.0") `shouldEqual` Match

  describe "encodeCompat" do
    it "serializes to the committed compat.json bytes exactly" do
      encodeCompat
        { packageSet: Just "77.4.0"
        , pursPin: "0.15.16"
        , pursMin: "0.15.15"
        , pursMax: "0.15.16"
        , packages: Map.fromFoldable
            [ Tuple "arrays" "7.3.0"
            , Tuple "foldable-traversable" "6.0.0"
            , Tuple "prelude" "6.0.2"
            ]
        }
        `shouldEqual` committedCompat
    it "emits {} for empty packages and null for an absent package set" do
      encodeCompat { packageSet: Nothing, pursPin: "0.15.16", pursMin: "0.15.16", pursMax: "0.15.16", packages: Map.empty }
        `shouldEqual` "{\n  \"packageSet\": null,\n  \"pursPin\": \"0.15.16\",\n  \"pursMin\": \"0.15.16\",\n  \"pursMax\": \"0.15.16\",\n  \"packages\": {}\n}\n"

  describe "readCompatCore" do
    it "reads back the offline core of a compat.json" do
      let core = readCompatCore committedCompat
      core.packageSet `shouldEqual` Just "77.4.0"
      Map.lookup "arrays" core.packages `shouldEqual` Just "7.3.0"
      Map.size core.packages `shouldEqual` 3
    it "degrades to empty on malformed input" do
      let core = readCompatCore "not json"
      core.packageSet `shouldEqual` Nothing
      Map.isEmpty core.packages `shouldEqual` true

  -- The payoff of the REGISTRY abstraction: the regenerate query is exercised against a stub
  -- registry, no network or `spago` needed.
  describe "querySupported (stub REGISTRY)" do
    let
      shadows = [ { pkg: "arrays", ver: "7.3.0" }, { pkg: "prelude", ver: "6.0.2" } ]
      noOverride _ = Nothing

    it "intersects each package's compilers, filtered to the constraint and sorted" do
      let
        stub = Map.fromFoldable
          [ Tuple (Tuple "arrays" "7.3.0") (Right [ "0.15.14", "0.15.15", "0.15.16" ])
          , Tuple (Tuple "prelude" "6.0.2") (Right [ "0.15.15", "0.15.16", "0.16.0" ])
          ]
      runStub stub (querySupported (Just ">=0.15.15 <0.16.0") noOverride shadows)
        `shouldEqual` Right [ "0.15.15", "0.15.16" ]

    it "short-circuits to Left when a package query fails (offline fallback path)" do
      let
        stub = Map.fromFoldable
          [ Tuple (Tuple "arrays" "7.3.0") (Left "spago: offline")
          , Tuple (Tuple "prelude" "6.0.2") (Right [ "0.15.16" ])
          ]
      runStub stub (querySupported Nothing noOverride shadows)
        `shouldEqual` Left "spago: offline"

    it "uses the version lookup (not the shadow's own version) to key the query" do
      let
        stub = Map.fromFoldable [ Tuple (Tuple "arrays" "9.9.9") (Right [ "0.15.16" ]) ]
        lookupVer = case _ of
          "arrays" -> Just "9.9.9"
          _ -> Nothing
      runStub stub (querySupported Nothing lookupVer [ { pkg: "arrays", ver: "7.3.0" } ])
        `shouldEqual` Right [ "0.15.16" ]

-- A pure interpreter for the REGISTRY effect: answer each query from a `(package, version)` table,
-- defaulting to a "no stub" `Left` for an unkeyed lookup. Lets the regenerate query run with no IO.
runStub :: forall a. Map (Tuple String String) (Either String (Array String)) -> Run (Registry.REGISTRY + ()) a -> a
runStub table = extract <<< Registry.interpret handler
  where
  handler :: RegistryF ~> Run ()
  handler = case _ of
    SupportedCompilers package version reply ->
      pure (reply (fromMaybe (Left ("no stub for " <> package <> "@" <> version)) (Map.lookup (Tuple package version) table)))

leftContains :: String -> Either String { min :: String, max :: String } -> Boolean
leftContains needle = case _ of
  Left msg -> Str.contains (Str.Pattern needle) msg
  Right _ -> false
