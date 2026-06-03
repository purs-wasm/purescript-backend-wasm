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
import Test.E2E.PreludeSemigroup as PreludeSemigroup
import Test.E2E.PreludeMonoid as PreludeMonoid
import Test.E2E.PreludeShow as PreludeShow
import Test.E2E.PreludeEqOrd as PreludeEqOrd
import Test.E2E.PreludeFunctor as PreludeFunctor
import Test.E2E.PreludeMonad as PreludeMonad
import Test.E2E.PreludeFnInstance as PreludeFnInstance
import Test.E2E.PreludeGeneric as PreludeGeneric
import Test.E2E.PreludeGenericShowCompare as PreludeGenericShowCompare
import Test.E2E.PreludeGuards as PreludeGuards
import Test.E2E.ExprEval as ExprEval
import Test.E2E.FFI as FFI
import Test.E2E.PreludeErased as PreludeErased
import Test.E2E.RecordUnsafe as RecordUnsafe
import Test.E2E.RecordInstances as RecordInstances
import Test.E2E.TailCall as TailCall
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
  PreludeSemigroup.spec
  PreludeMonoid.spec
  PreludeShow.spec
  PreludeEqOrd.spec
  PreludeFunctor.spec
  PreludeMonad.spec
  PreludeFnInstance.spec
  PreludeGeneric.spec
  PreludeGenericShowCompare.spec
  PreludeGuards.spec
  ExprEval.spec
  FFI.spec
  PreludeErased.spec
  RecordUnsafe.spec
  RecordInstances.spec
  TailCall.spec
