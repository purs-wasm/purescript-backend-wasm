-- | Aggregating entry point for the compiler package's end-to-end suites. Each
-- | slice exposes a `spec`; this module wires them into one runner (mirroring
-- | `Test.Unit.Compiler` for the unit suites).
module Test.E2E.Compiler where

import Prelude

import Effect (Effect)
import Test.E2E.Slice0 as Slice0
import Test.E2E.Slice1 as Slice1
import Test.E2E.Slice2 as Slice2
import Test.E2E.Slice2b as Slice2b
import Test.E2E.Slice3 as Slice3
import Test.E2E.Slice4a as Slice4a
import Test.E2E.Slice4b as Slice4b
import Test.E2E.Slice4c as Slice4c
import Test.E2E.Link as Link
import Test.E2E.Records as Records
import Test.E2E.PreludeArith as PreludeArith
import Test.E2E.PreludeCompare as PreludeCompare
import Test.E2E.PreludeBool as PreludeBool
import Test.E2E.PreludeNumber as PreludeNumber
import Test.E2E.PreludeEuclid as PreludeEuclid
import Test.E2E.PreludeField as PreludeField
import Test.E2E.PreludeBounded as PreludeBounded
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Slice0.spec
  Slice1.spec
  Slice2.spec
  Slice2b.spec
  Slice3.spec
  Slice4a.spec
  Slice4b.spec
  Slice4c.spec
  Records.spec
  Link.spec
  PreludeArith.spec
  PreludeCompare.spec
  PreludeBool.spec
  PreludeNumber.spec
  PreludeEuclid.spec
  PreludeField.spec
  PreludeBounded.spec
