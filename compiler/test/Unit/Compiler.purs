-- | Aggregating entry point for the compiler package's unit suites. Each suite
-- | exposes a `spec`; this module wires them into a single runner.
module Test.Unit.Compiler where

import Prelude

import Effect (Effect)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Unit.PureScript.Backend.Wasm.Lower as Lower
import Test.Unit.PureScript.Backend.Wasm.Lower.FreeVars as FreeVars
import Test.Unit.PureScript.Backend.Wasm.Lower.Match as Match
import Test.Unit.PureScript.CoreFn as CoreFn
import Test.Unit.PureScript.ExternsFile as ExternsFile

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  CoreFn.spec
  ExternsFile.spec
  Lower.spec
  Match.spec
  FreeVars.spec
