-- | Unit tests for `loadShadowMap`, against the in-memory interpreter: an in-memory lib directory
-- | tree resolves to the right `Module name -> Shadow` map (with the package/version split and the
-- | corefn path), and an absent lib yields the empty map.
module Test.Unit.PursWasm.CLI.Ulib.Shadow (spec) where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), snd)
import PursWasm.CLI.Ulib.Shadow (loadShadowMap)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Unit.PursWasm.CLI.Effect.Memory (runMem, worldOfText)

spec :: Spec Unit
spec = describe "PursWasm.CLI.Ulib.Shadow.loadShadowMap" do

  it "maps each <lib>/<pkg>-<ver>/<Module>/corefn.json to its Shadow" do
    let
      world = worldOfText
        [ Tuple "lib/arrays-7.3.0/Data.Array/corefn.json" "{}"
        , Tuple "lib/foldable-traversable-6.0.0/Data.Foldable/corefn.json" "{}"
        ]
    let shadows = snd (runMem world (loadShadowMap "lib"))
    Map.size shadows `shouldEqual` 2
    Map.lookup "Data.Array" shadows
      `shouldEqual` Just
        { package: "arrays"
        , version: "7.3.0"
        , corefn: "lib/arrays-7.3.0/Data.Array/corefn.json"
        , foreignWasm: "lib/arrays-7.3.0/Data.Array/foreign.wasm"
        }
    Map.lookup "Data.Foldable" shadows
      `shouldEqual` Just
        { package: "foldable-traversable"
        , version: "6.0.0"
        , corefn: "lib/foldable-traversable-6.0.0/Data.Foldable/corefn.json"
        , foreignWasm: "lib/foldable-traversable-6.0.0/Data.Foldable/foreign.wasm"
        }

  it "is empty when the lib directory is absent" do
    let shadows = snd (runMem (worldOfText []) (loadShadowMap "lib"))
    Map.isEmpty shadows `shouldEqual` true
