-- | Unit tests for the foreign-provider ladder + `assemble`, run against the in-memory
-- | interpreter: we assert *which* provider is chosen and *which* external tool is invoked, with
-- | no disk and no `wasm-as` actually running (the payoff of the `run` effect abstraction).
module Test.Unit.PursWasm.CLI.Build.Foreign (spec) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst, snd)
import PursWasm.CLI.Build.Foreign (resolveForeign)
import PureScript.Backend.Wasm.CLI.Paths (wasmAsBin)
import PureScript.Backend.Wasm.CLI.Ulib.Shadow (Shadow)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Unit.PursWasm.CLI.Effect.Memory (runMem, worldOfText)

-- a lib entry whose `foreign.wasm` sits beside the shadow corefn (ADR 0031, flat `$LIB/<Module>/`)
showShadow :: Shadow
showShadow =
  { corefn: "lib/Data.Show/corefn.json"
  , foreignWasm: "lib/Data.Show/foreign.wasm"
  }

spec :: Spec Unit
spec = describe "PursWasm.CLI.Build.Foreign.resolveForeign" do

  it "uses a project-local foreign.wasm directly (no assembly)" do
    let world = worldOfText [ Tuple "output/Data.Foo/foreign.wasm" "<wasm bytes>" ]
    let Tuple w prov = runMem world (resolveForeign "bin" Map.empty "lib" "output" "bundle" "Data.Foo")
    prov.wasm `shouldEqual` Just "output/Data.Foo/foreign.wasm"
    prov.assembled `shouldEqual` false
    Array.length w.execs `shouldEqual` 0

  it "uses the lib's per-module foreign.wasm for a ulib module's kept foreign (ADR 0031)" do
    let
      shadows = Map.singleton "Data.Show" showShadow
      world = worldOfText [ Tuple "lib/Data.Show/foreign.wasm" "<wasm>" ]
    let Tuple w prov = runMem world (resolveForeign "bin" shadows "lib" "output" "bundle" "Data.Show")
    prov.wasm `shouldEqual` Just "lib/Data.Show/foreign.wasm"
    prov.assembled `shouldEqual` false
    Array.length w.execs `shouldEqual` 0

  it "assembles a project foreign.wat *fragment* by wrapping it with the header and calling wasm-as" do
    let
      world = worldOfText
        [ Tuple "output/Data.Bar/foreign.wat" "(func (export \"f\") (result i32) (i32.const 1))"
        , Tuple "lib/_header.wat" "(; rt header ;)"
        ]
    let Tuple w prov = runMem world (resolveForeign "bin" Map.empty "lib" "output" "bundle" "Data.Bar")
    prov.wasm `shouldEqual` Just "bundle/Data.Bar.foreign.wasm"
    prov.assembled `shouldEqual` true
    -- exactly one wasm-as invocation, on the wrapped combined .wat → the .foreign.wasm output
    map fst w.execs `shouldEqual` [ wasmAsBin "bin" ]
    (Array.head w.execs >>= (Array.head <<< snd)) `shouldEqual` Just "bundle/Data.Bar.combined.wat"

  it "falls back to no in-wasm provider (JS loader) when nothing provides the module (ADR 0031: no global wat)" do
    -- a global ulib/<M>/foreign.wat is NOT consulted by the build anymore — it would have provided this
    let world = worldOfText [ Tuple "ulib/Data.Nope/foreign.wat" "(func (export \"f\") (result i32) (i32.const 1))" ]
    let Tuple w prov = runMem world (resolveForeign "bin" Map.empty "lib" "output" "bundle" "Data.Nope")
    prov.wasm `shouldEqual` Nothing
    prov.assembled `shouldEqual` false
    Array.length w.execs `shouldEqual` 0
