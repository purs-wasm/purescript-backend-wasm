-- | Tests for the incremental MIR cache wiring in `optimizeProgramCached` (ADR 0032
-- | phase 4). The type system cannot guarantee that a *cache hit* reproduces what a
-- | full optimize would have produced — the whole correctness of the feature rests on
-- | it — so these check the two load-bearing invariants directly, in memory (no FS):
-- |
-- |  1. **cold == warm**: optimizing with every module loaded from a prior run's cache
-- |     yields byte-identical finalized MIR, and writes nothing (all hits).
-- |  2. **selective invalidation**: changing one module's source hash re-optimizes only
-- |     that module; its unchanged dependency still hits.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Cache (spec) where

import Prelude

import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.MiddleEnd (CacheInput, CacheWrite, optimizeProgramCached)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn as CF
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

ann :: CF.Ann
ann = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

mod_ :: CF.ModuleName -> Array CF.ModuleName -> Array CF.Bind -> CF.Module
mod_ name imports decls =
  { name
  , path: ""
  , builtWith: "0.15.16"
  , imports: map (\m -> { ann, moduleName: m }) imports
  , exports: []
  , reExports: Object.empty
  , foreignNames: []
  , decls
  }

-- A two-module program with a cross-module reference: `Main.baz` applies `Dep.foo`.
depMod :: CF.Module
depMod = mod_ [ "Dep" ] []
  [ CF.NonRec ann "foo" (CF.Abs ann "x" (CF.Var ann (CF.Qualified Nothing "x")))
  , CF.NonRec ann "bar" (CF.Literal ann (CF.LitInt 5))
  ]

mainMod :: CF.Module
mainMod = mod_ [ "Main" ] [ [ "Dep" ] ]
  [ CF.NonRec ann "baz"
      (CF.App ann (CF.Var ann (CF.Qualified (Just [ "Dep" ]) "foo")) (CF.Var ann (CF.Qualified (Just [ "Dep" ]) "bar")))
  ]

program :: Array CF.Module
program = [ depMod, mainMod ]

sourceHashes :: Map String String
sourceHashes = Map.fromFoldable [ Tuple "Dep" "hDep", Tuple "Main" "hMain" ]

run :: CacheInput -> { modules :: Array M.Module, writes :: Array CacheWrite }
run cache = optimizeProgramCached true Set.empty Map.empty cache program

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd (incremental cache)" do
  let cold = run { sourceHashes, loaded: Map.empty }
  let loaded = Map.fromFoldable (map (\w -> Tuple w.name w.entry) cold.writes)

  it "writes one cache entry per cacheable module on a cold build" do
    map _.name cold.writes `shouldEqual` [ "Dep", "Main" ]

  it "reproduces identical finalized MIR from a fully warm cache" do
    let warm = run { sourceHashes, loaded }
    warm.modules `shouldEqual` cold.modules

  it "writes nothing when every module is a hit" do
    let warm = run { sourceHashes, loaded }
    warm.writes `shouldEqual` []

  it "re-optimizes only the module whose source changed (dependency still hits)" do
    let changed = Map.insert "Main" "hMain-v2" sourceHashes
    let warm = run { sourceHashes: changed, loaded }
    map _.name warm.writes `shouldEqual` [ "Main" ]
    warm.modules `shouldEqual` cold.modules
