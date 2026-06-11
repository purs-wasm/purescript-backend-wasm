-- | The compiler's end-to-end suite (ADR 0031 phase 5): each suite instantiates a fixture's prebuilt
-- | standalone wasm (`e2eCliPrebuild.mjs` must run first) and asserts its behaviour through the real
-- | `purs-wasm build` pipeline — the single path users actually run. This replaced the legacy
-- | in-process corefn-fixture runner + the global `ulib/<M>/foreign.wat` layer, both now retired.
-- | Host-interop marshalling is covered end to end: scalars/String/Array/Record/closure/Boolean/
-- | Number/nullary/Effect (`ForeignImport`/`Marshal`/`Record`/`Export`/`Effect`).
module Test.E2E.Cli where

import Prelude

import Effect (Effect)
import Test.E2E.Cli.AsPattern as AsPattern
import Test.E2E.Cli.Counter as Counter
import Test.E2E.Cli.Eff as Eff
import Test.E2E.Cli.EffectPrim as EffectPrim
import Test.E2E.Cli.ExprEval as ExprEval
import Test.E2E.Cli.ForeignEffect as ForeignEffect
import Test.E2E.Cli.ForeignExport as ForeignExport
import Test.E2E.Cli.ForeignImport as ForeignImport
import Test.E2E.Cli.ForeignMarshal as ForeignMarshal
import Test.E2E.Cli.ForeignRecord as ForeignRecord
import Test.E2E.Cli.FibAnd as FibAnd
import Test.E2E.Cli.IntConv as IntConv
import Test.E2E.Cli.Link as Link
import Test.E2E.Cli.NestedRecordPat as NestedRecordPat
import Test.E2E.Cli.PreludeArith as PreludeArith
import Test.E2E.Cli.PreludeBool as PreludeBool
import Test.E2E.Cli.PreludeBounded as PreludeBounded
import Test.E2E.Cli.PreludeCompare as PreludeCompare
import Test.E2E.Cli.PreludeEqOrd as PreludeEqOrd
import Test.E2E.Cli.PreludeErased as PreludeErased
import Test.E2E.Cli.PreludeEuclid as PreludeEuclid
import Test.E2E.Cli.PreludeField as PreludeField
import Test.E2E.Cli.PreludeFnInstance as PreludeFnInstance
import Test.E2E.Cli.PreludeFunctor as PreludeFunctor
import Test.E2E.Cli.PreludeGeneric as PreludeGeneric
import Test.E2E.Cli.PreludeGenericShowCompare as PreludeGenericShowCompare
import Test.E2E.Cli.PreludeGuards as PreludeGuards
import Test.E2E.Cli.PreludeMonad as PreludeMonad
import Test.E2E.Cli.PreludeMonoid as PreludeMonoid
import Test.E2E.Cli.PreludeNumber as PreludeNumber
import Test.E2E.Cli.PreludeSemigroup as PreludeSemigroup
import Test.E2E.Cli.PreludeShow as PreludeShow
import Test.E2E.Cli.RecordInstances as RecordInstances
import Test.E2E.Cli.RecordUnsafe as RecordUnsafe
import Test.E2E.Cli.Records as Records
import Test.E2E.Cli.Scalars as Scalars
import Test.E2E.Cli.DataTypes as DataTypes
import Test.E2E.Cli.Closures as Closures
import Test.E2E.Cli.Recursion as Recursion
import Test.E2E.Cli.TypeClasses as TypeClasses
import Test.E2E.Cli.Literals as Literals
import Test.E2E.Cli.Strings as Strings
import Test.E2E.Cli.Arrays as Arrays
import Test.E2E.Cli.StackSafe as StackSafe
import Test.E2E.Cli.TailCall as TailCall
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

main :: Effect Unit
main = runSpecAndExitProcess [ consoleReporter ] do
  Scalars.spec
  DataTypes.spec
  Closures.spec
  Recursion.spec
  TypeClasses.spec
  Literals.spec
  Strings.spec
  Arrays.spec
  PreludeArith.spec
  PreludeNumber.spec
  PreludeField.spec
  PreludeBool.spec
  PreludeCompare.spec
  PreludeEqOrd.spec
  PreludeEuclid.spec
  PreludeBounded.spec
  PreludeSemigroup.spec
  PreludeMonoid.spec
  PreludeShow.spec
  PreludeErased.spec
  PreludeFnInstance.spec
  PreludeFunctor.spec
  PreludeMonad.spec
  PreludeGeneric.spec
  PreludeGenericShowCompare.spec
  PreludeGuards.spec
  Records.spec
  RecordInstances.spec
  RecordUnsafe.spec
  AsPattern.spec
  NestedRecordPat.spec
  ExprEval.spec
  IntConv.spec
  FibAnd.spec
  Link.spec
  TailCall.spec
  StackSafe.spec
  Eff.spec
  EffectPrim.spec
  Counter.spec
  ForeignImport.spec
  ForeignMarshal.spec
  ForeignRecord.spec
  ForeignExport.spec
  ForeignEffect.spec
