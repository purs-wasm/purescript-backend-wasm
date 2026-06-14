-- | Aggregating entry point for the compiler package's unit suites. Each suite
-- | exposes a `spec`; this module wires them into a single runner.
module Test.Unit.Compiler where

import Prelude

import Effect (Effect)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Unit.PureScript.Backend.Wasm.Codegen.Caf as Caf
import Test.Unit.PureScript.Backend.Wasm.Externs as Externs
import Test.Unit.PureScript.Backend.Wasm.Lower as Lower
import Test.Unit.PureScript.Backend.Wasm.Lower.Match as Match
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift as LambdaLift
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.FreeVars as FreeVars
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify as Simplify
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize as Specialize
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim as DictElim
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify as Impurify
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity as Purity
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize as Serialize
import Test.Unit.PureScript.Backend.Wasm.SourceForeigns as SourceForeigns
import Test.Unit.PureScript.Backend.Wasm.Ulib.Interface as UlibInterface
import Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Transl as Transl
import Test.Unit.PureScript.CoreFn as CoreFn
import Test.Unit.PureScript.ExternsFile as ExternsFile

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  CoreFn.spec
  ExternsFile.spec
  Externs.spec
  Caf.spec
  Lower.spec
  Match.spec
  Transl.spec
  LambdaLift.spec
  Simplify.spec
  Specialize.spec
  DictElim.spec
  Impurify.spec
  Purity.spec
  Serialize.spec
  SourceForeigns.spec
  UlibInterface.spec
  FreeVars.spec
