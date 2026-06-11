-- | Aggregating entry point for the CLI-driven e2e suite (ADR 0031 phase 5): each suite instantiates
-- | a fixture's prebuilt standalone wasm (`e2eCliPrebuild.mjs` must run first) and asserts its
-- | behaviour through the real `purs-wasm build` pipeline. Grows as suites migrate off the legacy
-- | corefn-fixture runner (`Test.E2E.Legacy`); once it covers everything, the legacy path + the global
-- | `ulib/<M>/foreign.wat` layer are retired.
module Test.E2E.Cli where

import Prelude

import Effect (Effect)
import Test.E2E.Cli.AsPattern as AsPattern
import Test.E2E.Cli.NestedRecordPat as NestedRecordPat
import Test.E2E.Cli.PreludeArith as PreludeArith
import Test.E2E.Cli.PreludeBool as PreludeBool
import Test.E2E.Cli.PreludeEuclid as PreludeEuclid
import Test.E2E.Cli.PreludeGuards as PreludeGuards
import Test.E2E.Cli.Records as Records
import Test.E2E.Cli.TailCall as TailCall
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  PreludeArith.spec
  PreludeBool.spec
  PreludeEuclid.spec
  PreludeGuards.spec
  Records.spec
  AsPattern.spec
  NestedRecordPat.spec
  TailCall.spec
