-- | Aggregating entry point for `cli-lib`'s unit suites. Each suite exposes a `spec`; this wires
-- | them into one runner. (Pure logic and the in-memory effect interpreter only — the Node-bound
-- | interpreters are exercised by the binaries that depend on this library.)
module Test.Unit.PureScript.Backend.Wasm.CLI where

import Prelude

import Effect (Effect)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Unit.PureScript.Backend.Wasm.CLI.Compat as Compat
import Test.Unit.PureScript.Backend.Wasm.CLI.Module as Module
import Test.Unit.PureScript.Backend.Wasm.CLI.Ulib.Manifest as UlibManifest
import Test.Unit.PureScript.Backend.Wasm.CLI.Ulib.Shadow as UlibShadow

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Module.spec
  Compat.spec
  UlibShadow.spec
  UlibManifest.spec
