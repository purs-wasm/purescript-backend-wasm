-- | Aggregating entry point for `purs-wasm`'s unit suites. Each suite exposes a `spec`; this
-- | wires them into one runner. (Pure logic only — the IO-bound commands are covered by the
-- | differential-test harness against `bin`.)
module Test.Unit.PursWasm where

import Prelude

import Effect (Effect)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Unit.PursWasm.CLI.Build.Foreign as BuildForeign
import Test.Unit.PursWasm.CLI.Build.Loader as BuildLoader
import Test.Unit.PursWasm.CLI.Compat as Compat
import Test.Unit.PursWasm.CLI.Module as Module
import Test.Unit.PursWasm.CLI.Ulib as Ulib
import Test.Unit.PursWasm.CLI.Ulib.Compat as UlibCompat
import Test.Unit.PursWasm.CLI.Ulib.Shadow as UlibShadow
import Test.Unit.PursWasm.CLI.Ulib.Version as UlibVersion

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Module.spec
  Compat.spec
  UlibVersion.spec
  UlibShadow.spec
  Ulib.spec
  UlibCompat.spec
  BuildForeign.spec
  BuildLoader.spec
