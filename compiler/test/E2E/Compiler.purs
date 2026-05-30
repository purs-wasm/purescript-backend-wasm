-- | Aggregating entry point for the compiler package's end-to-end suites. Each
-- | slice exposes a `spec`; this module wires them into one runner (mirroring
-- | `Test.Unit.Compiler` for the unit suites).
module Test.E2E.Compiler where

import Prelude

import Effect (Effect)
import Test.E2E.Slice0 as Slice0
import Test.E2E.Slice1 as Slice1
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Slice0.spec
  Slice1.spec
