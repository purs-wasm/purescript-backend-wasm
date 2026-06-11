-- | LEGACY e2e runner (ADR 0031 phase 5): links hand-authored `corefn.json` fixtures **in process**
-- | via the compiler library, wiring ulib foreigns from the global `ulib/<M>/foreign.wasm` layer
-- | (`Test.E2E.Wasm`'s `ulibImports`). Kept running for coverage while suites migrate to the
-- | CLI-driven `Test.E2E.Cli` (real `purs-wasm build` pipeline); retired — together with the global
-- | wat layer and `build-ulib.mjs` — once `Test.E2E.Cli` covers everything.
module Test.E2E.Legacy where

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
import Test.E2E.EffectPrim as EffectPrim
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
import Test.E2E.FFIExport as FFIExport
import Test.E2E.PointFree as PointFree
import Test.E2E.PreludeErased as PreludeErased
import Test.E2E.RecordUnsafe as RecordUnsafe
import Test.E2E.RecordInstances as RecordInstances
import Test.E2E.TailCall as TailCall
import Test.E2E.StackSafe as StackSafe
import Test.E2E.Eff as Eff
import Test.E2E.Counter as Counter
import Test.E2E.HostEff as HostEff
import Test.E2E.IntConv as IntConv
import Test.E2E.FibAnd as FibAnd
import Test.E2E.AsPattern as AsPattern
import Test.E2E.NestedRecordPat as NestedRecordPat
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
  EffectPrim.spec
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
  FFIExport.spec
  PointFree.spec
  PreludeErased.spec
  RecordUnsafe.spec
  RecordInstances.spec
  TailCall.spec
  StackSafe.spec
  Eff.spec
  Counter.spec
  HostEff.spec
  IntConv.spec
  FibAnd.spec
  AsPattern.spec
  NestedRecordPat.spec
