-- | Unit tests for the CAF globalization analysis (`Codegen.Caf`, ADR 0006): the
-- | cycle exclusion and the dependency-topological init order — logic the type system
-- | cannot guarantee. Programs are hand-built (a CAF body is a chain of `RCallKnown`
-- | references to the CAFs it depends on); only `cafPlan`'s graph reasoning is exercised.
module Test.Unit.PureScript.Backend.Wasm.Codegen.Caf (spec) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Codegen.Caf (CafPlan, cafPlan)
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Atom(..), FuncName(..), IRFunc, Program, Rep(..), Rhs(..), Slot(..), VarRef(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- A program from a list of functions; only `funcs` is consulted by `cafPlan`.
prog :: Array IRFunc -> Program
prog funcs = { funcs, labels: [], exportSigs: Object.empty }

-- An arity-0 CAF whose body references each named CAF in turn (`RCallKnown … []`).
cafFn :: String -> Array String -> IRFunc
cafFn name deps =
  { name: FuncName name, params: [], result: Boxed, body: refs 0 deps, export: Nothing, localCount: Array.length deps + 1 }
  where
  refs i ds = case Array.uncons ds of
    Nothing -> Return (ALitInt 0)
    Just { head, tail } -> Let (Slot i) Boxed (RCallKnown (FuncName head) []) (refs (i + 1) tail)

hasGlobal :: String -> CafPlan -> Boolean
hasGlobal name plan = Map.member (FuncName name) plan.globals

-- `a` is initialised before `b` in the plan's init order.
precedes :: String -> String -> Array FuncName -> Boolean
precedes a b order = case Array.elemIndex (FuncName a) order, Array.elemIndex (FuncName b) order of
  Just i, Just j -> i < j
  _, _ -> false

spec :: Spec Unit
spec = describe "Codegen.Caf.cafPlan" do
  it "globalizes a dependency chain and initialises leaf-first" do
    let plan = cafPlan (prog [ cafFn "a" [ "b" ], cafFn "b" [ "c" ], cafFn "c" [] ])
    hasGlobal "a" plan `shouldEqual` true
    hasGlobal "b" plan `shouldEqual` true
    hasGlobal "c" plan `shouldEqual` true
    precedes "c" "b" plan.initOrder `shouldEqual` true
    precedes "b" "a" plan.initOrder `shouldEqual` true

  it "excludes a value-level cycle (both members)" do
    let plan = cafPlan (prog [ cafFn "a" [ "b" ], cafFn "b" [ "a" ] ])
    hasGlobal "a" plan `shouldEqual` false
    hasGlobal "b" plan `shouldEqual` false

  it "excludes a self-referential CAF" do
    let plan = cafPlan (prog [ cafFn "a" [ "a" ] ])
    hasGlobal "a" plan `shouldEqual` false

  it "initialises a diamond's shared dependency first" do
    let plan = cafPlan (prog [ cafFn "a" [ "b", "c" ], cafFn "b" [ "d" ], cafFn "c" [ "d" ], cafFn "d" [] ])
    Map.size plan.globals `shouldEqual` 4
    precedes "d" "b" plan.initOrder `shouldEqual` true
    precedes "d" "c" plan.initOrder `shouldEqual` true
    precedes "b" "a" plan.initOrder `shouldEqual` true
    precedes "c" "a" plan.initOrder `shouldEqual` true

  it "still globalizes an acyclic CAF that depends on a cyclic one" do
    -- b,c form a cycle; a depends on b but is not itself on a cycle
    let plan = cafPlan (prog [ cafFn "a" [ "b" ], cafFn "b" [ "c" ], cafFn "c" [ "b" ] ])
    hasGlobal "a" plan `shouldEqual` true
    hasGlobal "b" plan `shouldEqual` false
    hasGlobal "c" plan `shouldEqual` false

  it "excludes a function (arity > 0) and a closure-ref-typed value" do
    let
      f = { name: FuncName "f", params: [ Boxed ], result: Boxed, body: Return (ALitInt 0), export: Nothing, localCount: 1 }
      g = { name: FuncName "g", params: [], result: CloRef, body: Return (ALitInt 0), export: Nothing, localCount: 1 }
      plan = cafPlan (prog [ f, g ])
    hasGlobal "f" plan `shouldEqual` false
    hasGlobal "g" plan `shouldEqual` false
