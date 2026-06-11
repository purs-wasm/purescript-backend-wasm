-- | Aggregating entry point for `ulib-tooling`'s unit suites (the maintainer CLI). Each suite exposes
-- | a `spec`; this wires them into one runner. Pure logic + the in-memory interpreter; the IO-bound
-- | commands are covered end to end by the compiler's integration tests (which run `ulib install`).
module Test.Unit.UlibTooling where

import Prelude

import Effect (Effect)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Unit.UlibTooling.Commands as Commands
import Test.Unit.UlibTooling.Compat as Compat
import Test.Unit.UlibTooling.Version as Version

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Version.spec
  Commands.spec
  Compat.spec
