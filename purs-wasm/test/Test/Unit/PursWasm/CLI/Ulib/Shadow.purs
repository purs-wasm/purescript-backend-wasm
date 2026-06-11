-- | Unit tests for `loadShadowMap`, against the in-memory interpreter: a flat in-memory lib
-- | directory tree (`$LIB/<Module>/`, ADR 0031 §2.2) resolves to the right `Module name -> Shadow`
-- | map (corefn + foreign.wasm candidate paths), and an absent lib yields the empty map.
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

  it "maps each <lib>/<Module>/corefn.json to its Shadow" do
    let
      world = worldOfText
        [ Tuple "lib/Data.Array/corefn.json" "{}"
        , Tuple "lib/Data.Foldable/corefn.json" "{}"
        ]
    let shadows = snd (runMem world (loadShadowMap "lib"))
    Map.size shadows `shouldEqual` 2
    Map.lookup "Data.Array" shadows
      `shouldEqual` Just
        { corefn: "lib/Data.Array/corefn.json"
        , foreignWasm: "lib/Data.Array/foreign.wasm"
        }
    Map.lookup "Data.Foldable" shadows
      `shouldEqual` Just
        { corefn: "lib/Data.Foldable/corefn.json"
        , foreignWasm: "lib/Data.Foldable/foreign.wasm"
        }

  it "ignores the self-describing ulib-manifest.json at the lib root (not a module dir)" do
    let
      world = worldOfText
        [ Tuple "lib/Data.Array/corefn.json" "{}"
        , Tuple "lib/ulib-manifest.json" "{}"
        ]
    let shadows = snd (runMem world (loadShadowMap "lib"))
    Map.size shadows `shouldEqual` 1
    Map.lookup "ulib-manifest.json" shadows `shouldEqual` Nothing
    Map.lookup "Data.Array" shadows `shouldEqual`
      Just { corefn: "lib/Data.Array/corefn.json", foreignWasm: "lib/Data.Array/foreign.wasm" }

  it "is empty when the lib directory is absent" do
    let shadows = snd (runMem (worldOfText []) (loadShadowMap "lib"))
    Map.isEmpty shadows `shouldEqual` true
