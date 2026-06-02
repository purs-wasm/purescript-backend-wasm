-- | The wasm-GC value-type substrate the code generator targets (ADR 0001), built
-- | once per module, plus the codegen `Ctx` that threads it. Every other
-- | `Codegen.*` module is parameterised over a `Ctx`, so this is their shared
-- | foundation.
module PureScript.Backend.Wasm.Codegen.RuntimeTypes
  ( RuntimeTypes
  , Ctx
  , buildRuntimeTypes
  , repType
  ) where

import Prelude

import Binaryen as B
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Lower.IR (Rep(..))

-- | The module's runtime heap types, plus the (non-null) reference value types
-- | derived from them for `ref.cast` targets, field reads, and signatures.
type RuntimeTypes =
  { intHt :: B.HeapType
  , valsHt :: B.HeapType
  , adtHt :: B.HeapType
  , cloHt :: B.HeapType
  , labelIdsHt :: B.HeapType
  , recHt :: B.HeapType
  , numHt :: B.HeapType
  , bytesHt :: B.HeapType
  , strHt :: B.HeapType
  , codeHt :: B.HeapType
  , refInt :: B.Type
  , refVals :: B.Type
  , refAdt :: B.Type
  , refClo :: B.Type
  , refLabelIds :: B.Type
  , refRec :: B.Type
  , refNum :: B.Type
  , refBytes :: B.Type
  , refStr :: B.Type
  , refCode :: B.Type
  }

-- | `params` is the representation of the function currently being generated,
-- | so a `local.get` uses the slot's actual type (a code function's local 0 is
-- | `(ref $Clo)`, not `eqref`).
type Ctx =
  { mod :: B.Module
  , rt :: RuntimeTypes
  , params :: Array Rep
  -- | The representation of every local slot (parameters first, then `Let`-bound
  -- | temporaries), so codegen can declare and read each local at its chosen wasm
  -- | type and box/unbox only at representation boundaries.
  , localReps :: Array Rep
  }

-- | Build the value type group (`$Vals` / `$Int` / `$ADT` / `$Clo`) and, in a
-- | separate recursion group, the closure code signature `$Code`. `$Clo` holds
-- | its code as a generic `funcref` (not `(ref $Code)`), which keeps `$Code` out
-- | of `$Clo`'s recursion group so a lifted function's structurally-equal type
-- | matches `$Code` for `call_ref`.
buildRuntimeTypes :: B.Module -> Effect RuntimeTypes
buildRuntimeTypes _ = do
  tb <- B.typeBuilderCreate 9
  B.typeBuilderSetArrayType tb 0 B.eqref true -- $Vals = (array (mut eqref))
  B.typeBuilderSetStructType tb 1 [ { ty: B.i32, mutable: false } ] -- $Int (also $Char)
  refValsTmp <- B.typeBuilderGetTempHeapType tb 0 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 2 [ { ty: B.i32, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $ADT
  B.typeBuilderSetStructType tb 3 [ { ty: B.funcref, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $Clo
  B.typeBuilderSetArrayType tb 4 B.i32 true -- $LabelIds = (array (mut i32)); mut so recSet/recDelete can rebuild it
  refLabelIdsTmp <- B.typeBuilderGetTempHeapType tb 4 >>= \h -> B.typeBuilderGetTempRefType tb h false
  -- $Rec = (struct (ref $LabelIds) (ref $Vals)) — parallel label-id / value arrays
  B.typeBuilderSetStructType tb 5 [ { ty: refLabelIdsTmp, mutable: false }, { ty: refValsTmp, mutable: false } ]
  B.typeBuilderSetStructType tb 6 [ { ty: B.f64, mutable: false } ] -- $Num = (struct f64)
  B.typeBuilderSetArrayType tb 7 B.i32 true -- $Bytes = (array (mut i8)); built with i32 operands
  refBytesTmp <- B.typeBuilderGetTempHeapType tb 7 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 8 [ { ty: refBytesTmp, mutable: false } ] -- $Str = (struct (ref $Bytes))
  main <- B.typeBuilderBuildAndDispose tb 9
  case main of
    [ valsHt, intHt, adtHt, cloHt, labelIdsHt, recHt, numHt, bytesHt, strHt ] -> do
      let refClo = B.typeFromHeapType cloHt false
      tb2 <- B.typeBuilderCreate 1
      B.typeBuilderSetSignatureType tb2 0 (B.createType [ refClo, B.eqref ]) B.eqref
      codeGroup <- B.typeBuilderBuildAndDispose tb2 1
      case codeGroup of
        [ codeHt ] -> pure
          { intHt
          , valsHt
          , adtHt
          , cloHt
          , labelIdsHt
          , recHt
          , numHt
          , bytesHt
          , strHt
          , codeHt
          , refInt: B.typeFromHeapType intHt false
          , refVals: B.typeFromHeapType valsHt false
          , refAdt: B.typeFromHeapType adtHt false
          , refClo
          , refLabelIds: B.typeFromHeapType labelIdsHt false
          , refRec: B.typeFromHeapType recHt false
          , refNum: B.typeFromHeapType numHt false
          , refBytes: B.typeFromHeapType bytesHt false
          , refStr: B.typeFromHeapType strHt false
          , refCode: B.typeFromHeapType codeHt false
          }
        _ -> throwException (error "Codegen: expected exactly 1 code heap type")
    _ -> throwException (error "Codegen: expected exactly 9 runtime heap types")

-- | The wasm value type for an IR representation.
repType :: Ctx -> Rep -> B.Type
repType ctx = case _ of
  I32 -> B.i32
  F64 -> B.f64
  Boxed -> B.eqref
  CloRef -> ctx.rt.refClo
