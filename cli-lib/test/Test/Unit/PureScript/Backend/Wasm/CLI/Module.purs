module Test.Unit.PureScript.Backend.Wasm.CLI.Module (spec) where

import Prelude

import Data.Map as Map
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.CLI.Module (entryRoot, printModname, reachableClosure)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.CLI.Module" do

  describe "printModname / entryRoot" do
    it "round-trips a dotted module name" do
      printModname [ "Data", "Maybe" ] `shouldEqual` "Data.Maybe"
      entryRoot "Data.Maybe" `shouldEqual` [ "Data", "Maybe" ]

  describe "reachableClosure" do
    let
      imports = Map.fromFoldable
        [ Tuple "A" [ "B" ], Tuple "B" [ "C" ], Tuple "C" [], Tuple "D" [ "A" ] ]

    it "follows the import graph transitively from the roots" do
      reachableClosure [ [ "A" ] ] imports `shouldEqual` Set.fromFoldable [ "A", "B", "C" ]

    it "excludes modules not reachable from the roots (D depends on A, not vice versa)" do
      Set.member "D" (reachableClosure [ [ "A" ] ] imports) `shouldEqual` false

    it "a root with no imports is just itself" do
      reachableClosure [ [ "C" ] ] imports `shouldEqual` Set.singleton "C"

    it "terminates on a cycle" do
      let cyclic = Map.fromFoldable [ Tuple "X" [ "Y" ], Tuple "Y" [ "X" ] ]
      reachableClosure [ [ "X" ] ] cyclic `shouldEqual` Set.fromFoldable [ "X", "Y" ]
