-- | Unit tests for the foreign-provider ladder + `assemble`, run against the in-memory
-- | interpreter: we assert *which* provider is chosen and *which* external tool is invoked, with
-- | no disk and no `wasm-as` actually running (the payoff of the `run` effect abstraction).
module Test.Unit.PursWasm.CLI.Build.Foreign (spec) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst, snd)
import PursWasm.CLI.Build.Foreign (resolveForeign)
import PursWasm.CLI.Build.Paths (wasmAsBin)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Unit.PursWasm.CLI.Effect.Memory (World, runMem, worldOfText)

spec :: Spec Unit
spec = describe "PursWasm.CLI.Build.Foreign.resolveForeign" do

  it "uses a project-local foreign.wasm directly (no assembly)" do
    let world = worldOfText [ Tuple "output/Data.Foo/foreign.wasm" "<wasm bytes>" ]
    let Tuple w prov = runMem world (resolveForeign "output" "bundle" "Data.Foo")
    prov.wasm `shouldEqual` Just "output/Data.Foo/foreign.wasm"
    prov.assembled `shouldEqual` false
    Array.length w.execs `shouldEqual` 0

  it "assembles a ulib foreign.wat *fragment* by wrapping it with the header and calling wasm-as" do
    let
      world = worldOfText
        [ Tuple "ulib/Data.Bar/foreign.wat" "(func (export \"f\") (result i32) (i32.const 1))"
        , Tuple "ulib/_header.wat" "(; rt header ;)"
        ]
    let Tuple w prov = runMem world (resolveForeign "output" "bundle" "Data.Bar")
    prov.wasm `shouldEqual` Just "bundle/Data.Bar.foreign.wasm"
    prov.assembled `shouldEqual` true
    -- exactly one wasm-as invocation, on the wrapped combined .wat → the .foreign.wasm output
    map fst w.execs `shouldEqual` [ wasmAsBin ]
    (Array.head w.execs >>= (Array.head <<< snd)) `shouldEqual` Just "bundle/Data.Bar.combined.wat"

  it "falls back to no in-wasm provider (JS loader) when nothing provides the module" do
    let Tuple w prov = runMem emptyTextWorld (resolveForeign "output" "bundle" "Data.Nope")
    prov.wasm `shouldEqual` Nothing
    prov.assembled `shouldEqual` false
    Array.length w.execs `shouldEqual` 0

  where
  emptyTextWorld :: World
  emptyTextWorld = worldOfText []
