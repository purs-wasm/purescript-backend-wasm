-- | The wasm-GC value-type substrate the code generator targets (ADR 0001), built
-- | once per module, plus the codegen `Ctx` that threads it. Every other
-- | `Codegen.*` module is parameterised over a `Ctx`, so this is their shared
-- | foundation.
module PureScript.Backend.Wasm.Codegen.RuntimeTypes
  ( RuntimeTypes
  , Ctx
  , DataStruct
  , Sig
  , buildRuntimeTypes
  , repType
  ) where

import Prelude

import Binaryen as B
import Data.Map (Map)
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Lower.IR (FuncName, Rep(..))

-- | A generated ADT struct type: an `$Data_<sig> = (sub $Data (struct i32 <reps>))`,
-- | or the tag-only base `$Data` itself. `ref` is the non-null reference type, for
-- | `ref.cast` / `struct.new` / `struct.get` (ADR 0013, front B).
type DataStruct = { ht :: B.HeapType, ref :: B.Type }

-- | A function's parameter and result representations, so a call site can box /
-- | unbox its arguments and result to match the callee's (possibly unboxed) ABI.
type Sig = { params :: Array Rep, result :: Rep }

-- | The module's runtime heap types, plus the (non-null) reference value types
-- | derived from them for `ref.cast` targets, field reads, and signatures.
type RuntimeTypes =
  { intHt :: B.HeapType
  , int64Ht :: B.HeapType
  , valsHt :: B.HeapType
  , cloHt :: B.HeapType
  , labelIdsHt :: B.HeapType
  , recHt :: B.HeapType
  , numHt :: B.HeapType
  , bytesHt :: B.HeapType
  , strHt :: B.HeapType
  , i32ArrHt :: B.HeapType
  , f64ArrHt :: B.HeapType
  , i64ArrHt :: B.HeapType
  , codeHt :: B.HeapType
  , refInt :: B.Type
  , refInt64 :: B.Type
  , refVals :: B.Type
  , refClo :: B.Type
  , refLabelIds :: B.Type
  , refRec :: B.Type
  , refNum :: B.Type
  , refBytes :: B.Type
  , refStr :: B.Type
  , refI32Arr :: B.Type
  , refF64Arr :: B.Type
  , refI64Arr :: B.Type
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
  -- | The representation the *current tail* must produce (what `Return` coerces to).
  -- | At the function body this is the function's result rep; inside a `LetJoin`
  -- | producer it is temporarily the join slot's rep (ADR 0022).
  , funcResult :: Rep
  -- | Whether the current position is the function's tail, so a `Let … (RCallKnown …)
  -- | (Return …)` may emit `return_call`. False inside a `LetJoin` producer block,
  -- | where a `return_call` would return from the whole function and skip the join.
  , tailPos :: Boolean
  -- | Every function's signature, keyed by name, so a call coerces its arguments to
  -- | the callee's parameter reps and reads the result at the callee's result rep.
  , sigs :: Map FuncName Sig
  -- | The top-level value bindings (CAFs) compiled to globals (ADR 0006), each with
  -- | the representation its global holds. A reference reads the global (`global.get`)
  -- | instead of calling the binding; the value is computed once by the synthesized
  -- | init (`start`) function. Empty when globalization finds no eligible CAF.
  , cafGlobals :: Map FuncName Rep
  -- | The tag-only base `$Data = (struct i32)`, cast to for reading any ADT value's
  -- | constructor tag (every constructor struct is a subtype).
  , dataBase :: DataStruct
  -- | One struct type per constructor field-rep signature (`$Data_<sig>`), keyed by
  -- | the signature; the empty signature maps to `dataBase`. Used to construct
  -- | (`struct.new`) and project (`ref.cast` + `struct.get`) ADT values.
  , dataStructs :: Map (Array Rep) DataStruct
  }

-- | Build the value types (`$Vals` / `$Int` / `$Clo` / `$Rec` / `$Str` / …) and, in a
-- | separate recursion group, the closure code signature `$Code`. `$Clo` holds
-- | its code as a generic `funcref` (not `(ref $Code)`), which keeps `$Code` out
-- | of `$Clo`'s recursion group so a lifted function's structurally-equal type
-- | matches `$Code` for `call_ref`.
buildRuntimeTypes :: B.Module -> Effect RuntimeTypes
buildRuntimeTypes _ = do
  tb <- B.typeBuilderCreate 12
  B.typeBuilderSetArrayType tb 0 B.eqref true -- $Vals = (array (mut eqref))
  B.typeBuilderSetStructType tb 1 [ { ty: B.i32, mutable: false } ] -- $Int (also $Char)
  refValsTmp <- B.typeBuilderGetTempHeapType tb 0 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 2 [ { ty: B.funcref, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $Clo
  B.typeBuilderSetArrayType tb 3 B.i32 true -- $LabelIds = (array (mut i32)); mut so recSet/recDelete can rebuild it
  refLabelIdsTmp <- B.typeBuilderGetTempHeapType tb 3 >>= \h -> B.typeBuilderGetTempRefType tb h false
  -- $Rec = (struct (ref $LabelIds) (ref $Vals)) — parallel label-id / value arrays
  B.typeBuilderSetStructType tb 4 [ { ty: refLabelIdsTmp, mutable: false }, { ty: refValsTmp, mutable: false } ]
  B.typeBuilderSetStructType tb 5 [ { ty: B.f64, mutable: false } ] -- $Num = (struct f64)
  B.typeBuilderSetArrayType tb 6 B.i32 true -- $Bytes = (array (mut i32)); one UTF-8 byte per i32 lane (not packed)
  refBytesTmp <- B.typeBuilderGetTempHeapType tb 6 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 7 [ { ty: refBytesTmp, mutable: false } ] -- $Str = (struct (ref $Bytes))
  -- $I32Arr / $F64Arr / $I64Arr (WasmBase, ADR 0026): packed unboxed numeric arrays. Each is acyclic,
  -- so Binaryen emits it as its own singleton rec group (like every value type above); adding them
  -- leaves the other types' canonical identity untouched, so the runtime ABI is unchanged. They
  -- are inlined in codegen (no `$rt.*` helper crosses to the runtime module), so runtime.wat does
  -- not declare them. $I32Arr is structurally identical to $Bytes and canonicalises with it today;
  -- it is kept distinct so a future packed-byte $Str representation cannot silently change it.
  B.typeBuilderSetArrayType tb 8 B.i32 true -- $I32Arr = (array (mut i32))
  B.typeBuilderSetArrayType tb 9 B.f64 true -- $F64Arr = (array (mut f64))
  B.typeBuilderSetStructType tb 10 [ { ty: B.i64, mutable: false } ] -- $Int64 = (struct i64)
  B.typeBuilderSetArrayType tb 11 B.i64 true -- $I64Arr = (array (mut i64)); packed native 64-bit lanes
  main <- B.typeBuilderBuildAndDispose tb 12
  case main of
    [ valsHt, intHt, cloHt, labelIdsHt, recHt, numHt, bytesHt, strHt, i32ArrHt, f64ArrHt, int64Ht, i64ArrHt ] -> do
      let refClo = B.typeFromHeapType cloHt false
      tb2 <- B.typeBuilderCreate 1
      B.typeBuilderSetSignatureType tb2 0 (B.createType [ refClo, B.eqref ]) B.eqref
      codeGroup <- B.typeBuilderBuildAndDispose tb2 1
      case codeGroup of
        [ codeHt ] -> pure
          { intHt
          , int64Ht
          , valsHt
          , cloHt
          , labelIdsHt
          , recHt
          , numHt
          , bytesHt
          , strHt
          , codeHt
          , i32ArrHt
          , f64ArrHt
          , i64ArrHt
          , refInt: B.typeFromHeapType intHt false
          , refInt64: B.typeFromHeapType int64Ht false
          , refVals: B.typeFromHeapType valsHt false
          , refClo
          , refLabelIds: B.typeFromHeapType labelIdsHt false
          , refRec: B.typeFromHeapType recHt false
          , refNum: B.typeFromHeapType numHt false
          , refBytes: B.typeFromHeapType bytesHt false
          , refStr: B.typeFromHeapType strHt false
          , refCode: B.typeFromHeapType codeHt false
          , refI32Arr: B.typeFromHeapType i32ArrHt false
          , refF64Arr: B.typeFromHeapType f64ArrHt false
          , refI64Arr: B.typeFromHeapType i64ArrHt false
          }
        _ -> throwException (error "Codegen: expected exactly 1 code heap type")
    _ -> throwException (error "Codegen: expected exactly 12 runtime heap types")

-- | The wasm value type for an IR representation.
repType :: Ctx -> Rep -> B.Type
repType ctx = case _ of
  I32 -> B.i32
  I64 -> B.i64
  F64 -> B.f64
  Boxed -> B.eqref
  CloRef -> ctx.rt.refClo