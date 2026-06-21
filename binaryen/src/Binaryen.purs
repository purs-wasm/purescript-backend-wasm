-- | Minimal FFI bindings to Binaryen.js.
-- |
-- | This is a thin, low-level layer: it mirrors the Binaryen API shape and
-- | leaves any higher-level IR-construction conveniences to callers. Anything
-- | that allocates into the module's arena or mutates the module is modelled
-- | as an `Effect`; pure type values (`i32`, `none`, ...) are not.
module Binaryen
  ( addFunction
  , addFunctionExport
  , addFunctionImport
  , addGlobal
  , arrayCopy
  , arrayGet
  , arrayLen
  , arrayNew
  , arrayNewFixed
  , arraySet
  , auto
  , block
  , blockNamed
  , br
  , brIf
  , brIfWithValue
  , brWithValue
  , call
  , callRef
  , createModule
  , createType
  , dispose
  , emitBinary
  , emitText
  , eqref
  , Export
  , Expression
  , f32
  , f64
  , f64Add
  , f64Const
  , f64ConvertI32S
  , f64Div
  , f64Eq
  , f64Lt
  , f64Mul
  , f64Sub
  , funcref
  , Function
  , getExpressionType
  , globalGet
  , globalSet
  , HeapType
  , i31GetS
  , i31New
  , i31ref
  , i32
  , i32Add
  , i32And
  , i32Const
  , i32DivS
  , i32Eq
  , i32Eqz
  , i32LtS
  , i32LtU
  , i32Mul
  , i32Ne
  , i32Or
  , i32RemS
  , i32Shl
  , i32ShrS
  , i32ShrU
  , i32Sub
  , i32TruncF64S
  , i32WrapI64
  , i32Xor
  , i64
  , i64And
  , i64Const
  , i64Eq
  , i64ExtendI32S
  , i64LtS
  , i64Or
  , i64RotL
  , i64RotR
  , i64Shl
  , i64ShrS
  , i64ShrU
  , i64Xor
  , if_
  , localGet
  , localSet
  , loop
  , Module
  , none
  , optimize
  , readBinary
  , refCast
  , refFunc
  , refNull
  , removeExport
  , returnCall
  , runPasses
  , setFeaturesGC
  , setStart
  , structGet
  , structNew
  , Type
  , TypeBuilder
  , typeBuilderBuildAndDispose
  , typeBuilderCreate
  , typeBuilderGetTempHeapType
  , typeBuilderGetTempRefType
  , typeBuilderSetArrayType
  , typeBuilderSetOpen
  , typeBuilderSetSignatureType
  , typeBuilderSetStructType
  , typeBuilderSetSubType
  , typeEq
  , typeFromHeapType
  , unreachable
  , validate
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Effect (Effect)
import Prim hiding (Type, Function)

-- | A Binaryen module: a mutable arena holding functions, exports, etc.
foreign import data Module :: Prim.Type

-- | An expression node (`ExpressionRef` in Binaryen.js).
foreign import data Expression :: Prim.Type

-- | A Binaryen value type (`Type` in Binaryen.js; an opaque numeric tag).
foreign import data Type :: Prim.Type

-- | A function added to a module (`FunctionRef`).
foreign import data Function :: Prim.Type

-- | An export added to a module (`ExportRef`).
foreign import data Export :: Prim.Type

-- | Create a fresh, empty module.
foreign import createModule :: Effect Module

foreign import disposeImpl :: Module -> Effect Unit

-- | Free the module's underlying memory. Use it once the module is no longer
-- | needed; the `Module` must not be touched afterwards.
dispose :: Module -> Effect Unit
dispose = disposeImpl

foreign import i32 :: Type
foreign import i64 :: Type
foreign import f32 :: Type
foreign import f64 :: Type

-- | The empty type, e.g. for a function that returns nothing.
foreign import none :: Type

-- | The "infer" type sentinel (`BinaryenTypeAuto`): when given as a `block`'s
-- | type, Binaryen infers it from the block's contents (its fall-through value
-- | and any branches to it).
foreign import auto :: Type

-- | Pack zero or more types into a single (tuple) type, used for function
-- | parameter and result signatures.
foreign import createType :: Array Type -> Type

foreign import localGetImpl :: Module -> Int -> Type -> Effect Expression

-- | Read local variable `index` (which has the given type).
localGet :: Module -> Int -> Type -> Effect Expression
localGet = localGetImpl

foreign import localSetImpl :: Module -> Int -> Expression -> Effect Expression

-- | Set local variable `index` to `value`. The resulting node is a statement
-- | (it has no value); sequence it inside a `block`.
localSet :: Module -> Int -> Expression -> Effect Expression
localSet = localSetImpl

foreign import blockImpl :: Module -> Array Expression -> Type -> Effect Expression

-- | Sequence expressions into an (anonymous) block whose value and type are
-- | those of its last child.
block :: Module -> Array Expression -> Type -> Effect Expression
block = blockImpl

foreign import blockNamedImpl :: Module -> String -> Array Expression -> Type -> Effect Expression

-- | A `block` with a `label` that `br`/`brIf` can target to exit early. Branches
-- | carrying a value must match the block's declared `Type`.
blockNamed :: Module -> String -> Array Expression -> Type -> Effect Expression
blockNamed = blockNamedImpl

foreign import loopImpl :: Module -> String -> Expression -> Effect Expression

-- | A `loop` with a `label`; a `br` to that label jumps back to the loop's start
-- | (a continue). The loop takes the type of its body.
loop :: Module -> String -> Expression -> Effect Expression
loop = loopImpl

foreign import brImpl :: Module -> String -> Effect Expression

-- | Unconditional branch to a `block`/`loop` `label`.
br :: Module -> String -> Effect Expression
br = brImpl

foreign import brIfImpl :: Module -> String -> Expression -> Effect Expression

-- | Branch to `label` iff `condition` is non-zero (no carried value).
brIf :: Module -> String -> Expression -> Effect Expression
brIf = brIfImpl

foreign import brWithValueImpl :: Module -> String -> Expression -> Effect Expression

-- | Unconditional branch to `label` carrying `value` (whose type must match the
-- | target block's type).
brWithValue :: Module -> String -> Expression -> Effect Expression
brWithValue = brWithValueImpl

foreign import brIfWithValueImpl :: Module -> String -> Expression -> Expression -> Effect Expression

-- | Branch to `label` iff `condition` is non-zero, carrying `value` (whose type
-- | must match the target block's type).
brIfWithValue :: Module -> String -> Expression -> Expression -> Effect Expression
brIfWithValue = brIfWithValueImpl

foreign import callImpl :: Module -> String -> Array Expression -> Type -> Effect Expression

-- | Call the internal function `target` with `operands`, yielding `returnType`.
call :: Module -> String -> Array Expression -> Type -> Effect Expression
call = callImpl

foreign import returnCallImpl :: Module -> String -> Array Expression -> Type -> Effect Expression

-- | A *tail* call to `target` (`return_call`): the current frame is replaced, so a
-- | tail-recursive chain runs in constant stack. Requires the `TailCall` feature.
returnCall :: Module -> String -> Array Expression -> Type -> Effect Expression
returnCall = returnCallImpl

foreign import i32AddImpl :: Module -> Expression -> Expression -> Effect Expression

i32Add :: Module -> Expression -> Expression -> Effect Expression
i32Add = i32AddImpl

foreign import i32SubImpl :: Module -> Expression -> Expression -> Effect Expression

i32Sub :: Module -> Expression -> Expression -> Effect Expression
i32Sub = i32SubImpl

foreign import i32MulImpl :: Module -> Expression -> Expression -> Effect Expression

i32Mul :: Module -> Expression -> Expression -> Effect Expression
i32Mul = i32MulImpl

foreign import i32DivSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.div_s`: signed integer division, truncating toward zero. Traps on
-- | division by zero and on `INT_MIN / -1`; callers must guard those.
i32DivS :: Module -> Expression -> Expression -> Effect Expression
i32DivS = i32DivSImpl

foreign import i32RemSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.rem_s`: signed remainder (sign follows the dividend). Traps on a zero
-- | divisor; callers must guard it.
i32RemS :: Module -> Expression -> Expression -> Effect Expression
i32RemS = i32RemSImpl

foreign import i32EqImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.eq`: 1 if the operands are equal, 0 otherwise.
i32Eq :: Module -> Expression -> Expression -> Effect Expression
i32Eq = i32EqImpl

foreign import i32NeImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.ne`: 1 if the operands differ, 0 otherwise.
i32Ne :: Module -> Expression -> Expression -> Effect Expression
i32Ne = i32NeImpl

foreign import i32LtUImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.lt_u`: 1 if `left < right` as unsigned, 0 otherwise.
i32LtU :: Module -> Expression -> Expression -> Effect Expression
i32LtU = i32LtUImpl

foreign import i32LtSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.lt_s`: 1 if `left < right` as signed, 0 otherwise.
i32LtS :: Module -> Expression -> Expression -> Effect Expression
i32LtS = i32LtSImpl

foreign import i32AndImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.and`: bitwise AND.
i32And :: Module -> Expression -> Expression -> Effect Expression
i32And = i32AndImpl

foreign import i32OrImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.or`: bitwise OR.
i32Or :: Module -> Expression -> Expression -> Effect Expression
i32Or = i32OrImpl

foreign import i32XorImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.xor`: bitwise XOR.
i32Xor :: Module -> Expression -> Expression -> Effect Expression
i32Xor = i32XorImpl

foreign import i64XorImpl :: Module -> Expression -> Expression -> Effect Expression
foreign import i64AndImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.and`: bitwise AND.
i64And :: Module -> Expression -> Expression -> Effect Expression
i64And = i64AndImpl

foreign import i64OrImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.or`: bitwise OR.
i64Or :: Module -> Expression -> Expression -> Effect Expression
i64Or = i64OrImpl

foreign import i64ShlImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.shl`: shift left.
i64Shl :: Module -> Expression -> Expression -> Effect Expression
i64Shl = i64ShlImpl

foreign import i64ShrSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.shr_s`: arithmetic (sign-propagating) shift right.
i64ShrS :: Module -> Expression -> Expression -> Effect Expression
i64ShrS = i64ShrSImpl

foreign import i64ShrUImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.shr_u`: logical (zero-fill) shift right.
i64ShrU :: Module -> Expression -> Expression -> Effect Expression
i64ShrU = i64ShrUImpl

foreign import i64RotLImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.rotl`: rotate left.
i64RotL :: Module -> Expression -> Expression -> Effect Expression
i64RotL = i64RotLImpl

foreign import i64RotRImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.rotr`: rotate right.
i64RotR :: Module -> Expression -> Expression -> Effect Expression
i64RotR = i64RotRImpl

foreign import i64EqImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.eq`: 1 if equal, 0 otherwise.
i64Eq :: Module -> Expression -> Expression -> Effect Expression
i64Eq = i64EqImpl

foreign import i64LtSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i64.lt_s`: 1 if `left < right` as signed, 0 otherwise.
i64LtS :: Module -> Expression -> Expression -> Effect Expression
i64LtS = i64LtSImpl

foreign import i64ExtendI32SImpl :: Module -> Expression -> Effect Expression

-- | `i64.extend_i32_s`: sign-extend an i32 to i64.
i64ExtendI32S :: Module -> Expression -> Effect Expression
i64ExtendI32S = i64ExtendI32SImpl

foreign import i32WrapI64Impl :: Module -> Expression -> Effect Expression

-- | `i32.wrap_i64`: the low 32 bits of an i64.
i32WrapI64 :: Module -> Expression -> Effect Expression
i32WrapI64 = i32WrapI64Impl

-- | `i64.xor`: bitwise XOR.
i64Xor :: Module -> Expression -> Expression -> Effect Expression
i64Xor = i64XorImpl

foreign import i32ShlImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.shl`: logical left shift (`left << (right & 31)`).
i32Shl :: Module -> Expression -> Expression -> Effect Expression
i32Shl = i32ShlImpl

foreign import i32ShrSImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.shr_s`: arithmetic right shift, sign-propagating (PureScript `shr`, JS `>>`).
i32ShrS :: Module -> Expression -> Expression -> Effect Expression
i32ShrS = i32ShrSImpl

foreign import i32ShrUImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `i32.shr_u`: logical right shift, zero-filling (PureScript `zshr`, JS `>>>`).
i32ShrU :: Module -> Expression -> Expression -> Effect Expression
i32ShrU = i32ShrUImpl

foreign import i32EqzImpl :: Module -> Expression -> Effect Expression

-- | `i32.eqz`: 1 if the operand is 0, 0 otherwise (logical NOT of a 0/1 value).
i32Eqz :: Module -> Expression -> Effect Expression
i32Eqz = i32EqzImpl

foreign import ifImpl :: Module -> Expression -> Expression -> Expression -> Effect Expression

-- | `if`: `if_ mod condition ifTrue ifFalse`. The result type is inferred from
-- | the arms (which must agree, modulo `unreachable`).
if_ :: Module -> Expression -> Expression -> Expression -> Effect Expression
if_ = ifImpl

foreign import unreachableImpl :: Module -> Effect Expression

-- | `unreachable`: traps if reached. Has the bottom type, so it unifies with
-- | any branch type (used as the default arm of an exhaustive `Switch`).
unreachable :: Module -> Effect Expression
unreachable = unreachableImpl

foreign import i32ConstImpl :: Module -> Int -> Effect Expression

foreign import i64ConstImpl :: Module -> Int -> Int -> Effect Expression

-- | `i64.const`: a 64-bit literal from its low / high 32-bit halves (binaryen takes
-- | the two i32 words). Used for constant initializers such as an i64 CAF global's
-- | throwaway zero; runtime i64 values come from the ops / `extend`.
i64Const :: Module -> Int -> Int -> Effect Expression
i64Const = i64ConstImpl

i32Const :: Module -> Int -> Effect Expression
i32Const = i32ConstImpl

foreign import i32TruncF64SImpl :: Module -> Expression -> Effect Expression

-- | `i32.trunc_f64_s`: truncate an `f64` toward zero to a signed `i32`.
i32TruncF64S :: Module -> Expression -> Effect Expression
i32TruncF64S = i32TruncF64SImpl

foreign import f64ConstImpl :: Module -> Number -> Effect Expression

f64Const :: Module -> Number -> Effect Expression
f64Const = f64ConstImpl

foreign import f64EqImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `f64.eq`: 1 if the operands are equal, 0 otherwise.
f64Eq :: Module -> Expression -> Expression -> Effect Expression
f64Eq = f64EqImpl

foreign import f64LtImpl :: Module -> Expression -> Expression -> Effect Expression

-- | `f64.lt`: 1 if `left < right`, 0 otherwise.
f64Lt :: Module -> Expression -> Expression -> Effect Expression
f64Lt = f64LtImpl

foreign import f64AddImpl :: Module -> Expression -> Expression -> Effect Expression
foreign import f64SubImpl :: Module -> Expression -> Expression -> Effect Expression
foreign import f64MulImpl :: Module -> Expression -> Expression -> Effect Expression
foreign import f64DivImpl :: Module -> Expression -> Expression -> Effect Expression

f64Add :: Module -> Expression -> Expression -> Effect Expression
f64Add = f64AddImpl

f64Sub :: Module -> Expression -> Expression -> Effect Expression
f64Sub = f64SubImpl

f64Mul :: Module -> Expression -> Expression -> Effect Expression
f64Mul = f64MulImpl

-- | `f64.div`: floating-point division.
f64Div :: Module -> Expression -> Expression -> Effect Expression
f64Div = f64DivImpl

foreign import f64ConvertI32SImpl :: Module -> Expression -> Effect Expression

-- | `f64.convert_i32_s`: widen a signed `i32` to `f64`.
f64ConvertI32S :: Module -> Expression -> Effect Expression
f64ConvertI32S = f64ConvertI32SImpl

-- --- Wasm GC ----------------------------------------------------------------
-- Binaryen.js 123 exposes no high-level GC API, so these wrap the raw
-- emscripten C API (see Binaryen.js for the heap marshalling). Heap types are
-- built in batches via `TypeBuilder` so that mutually-recursive types can refer
-- to one another (a slot can be referenced before it is defined).

-- | A GC heap type (struct / array / signature), as produced by `TypeBuilder`.
foreign import data HeapType :: Prim.Type

-- | Mutable scratch space for defining a batch of (possibly recursive) heap
-- | types; see `typeBuilderCreate` and `typeBuilderBuildAndDispose`.
foreign import data TypeBuilder :: Prim.Type

-- | The universal `eqref` value type — supertype of `i31ref` and every
-- | struct/array reference; the backend's boxed value type.
foreign import eqref :: Type

-- | The generic `funcref` value type (any function reference). Closures store
-- | their code as a `funcref` and `ref.cast` it to the precise `(ref $Code)` at
-- | the call site, which keeps the closure struct type out of the function
-- | type's recursion group (so the code function's own type matches).
foreign import funcref :: Type

-- | The `i31ref` value type (a 31-bit integer packed into a reference, no
-- | allocation). The backend's `Boolean`/`Unit` representation (ADR 0001).
foreign import i31ref :: Type

foreign import i31NewImpl :: Module -> Expression -> Effect Expression

-- | `ref.i31`: pack an `i32` (low 31 bits) into an `i31ref`.
i31New :: Module -> Expression -> Effect Expression
i31New = i31NewImpl

foreign import i31GetSImpl :: Module -> Expression -> Effect Expression

-- | `i31.get_s`: read the (sign-extended) `i32` out of an `i31ref`.
i31GetS :: Module -> Expression -> Effect Expression
i31GetS = i31GetSImpl

-- | Enable the GC and reference-types features. Required before validating or
-- | emitting a module that uses any construct below.
foreign import setFeaturesGC :: Module -> Effect Unit

-- | Create a `TypeBuilder` with `size` reserved slots (indices `0 .. size-1`).
foreign import typeBuilderCreate :: Int -> Effect TypeBuilder

-- | Define slot `index` as a struct with the given fields, in order.
foreign import typeBuilderSetStructType
  :: TypeBuilder -> Int -> Array { ty :: Type, mutable :: Boolean } -> Effect Unit

-- | Define slot `index` as an array of `element`, with the given mutability.
foreign import typeBuilderSetArrayType :: TypeBuilder -> Int -> Type -> Boolean -> Effect Unit

-- | Define slot `index` as a function signature. `params` and `results` are
-- | each a single (possibly tuple) value type — build a multi-parameter tuple
-- | with `createType`, and pass a lone type directly for a single result.
foreign import typeBuilderSetSignatureType :: TypeBuilder -> Int -> Type -> Type -> Effect Unit

-- | Mark slot `index` as **open** (extensible), so other slots may declare it as a
-- | supertype. The GC type system defaults to closed/final, which forbids subtyping.
foreign import typeBuilderSetOpen :: TypeBuilder -> Int -> Effect Unit

-- | Declare slot `index` a subtype of `supertype` (a temp heap type from the same
-- | builder, e.g. from `typeBuilderGetTempHeapType`). The supertype must be `open`.
foreign import typeBuilderSetSubType :: TypeBuilder -> Int -> HeapType -> Effect Unit

-- | A temporary heap type referring to slot `index`. It may be used in other
-- | slot definitions before that slot is defined — this is what lets recursive
-- | types be expressed.
foreign import typeBuilderGetTempHeapType :: TypeBuilder -> Int -> Effect HeapType

-- | A temporary `(ref null? ht)` value type, for use in slot definitions.
foreign import typeBuilderGetTempRefType :: TypeBuilder -> HeapType -> Boolean -> Effect Type

-- | Finalize all slots into canonical heap types (result length = the builder's
-- | `size`), disposing the builder. Throws if the type graph is invalid.
foreign import typeBuilderBuildAndDispose :: TypeBuilder -> Int -> Effect (Array HeapType)

-- | The `(ref null? ht)` value type for a finalized heap type.
foreign import typeFromHeapType :: HeapType -> Boolean -> Type

-- | The (already-finalized) result type of a built expression. Pure: binaryen
-- | computes and stores the type at construction.
foreign import getExpressionType :: Expression -> Type

-- | Identity comparison of two binaryen types (they are interned ids).
foreign import typeEq :: Type -> Type -> Boolean

-- | `struct.new`: allocate a struct of the heap type, with field initializers
-- | given in field order.
foreign import structNew :: Module -> HeapType -> Array Expression -> Effect Expression

-- | `struct.get`: read field `index` (of value type `fieldType`) from `ref`.
-- | The boolean is the sign extension, relevant only for packed fields.
foreign import structGet :: Module -> Int -> Expression -> Type -> Boolean -> Effect Expression

-- | `array.new`: allocate an array of the heap type with `size` elements, each
-- | initialised to `init`.
foreign import arrayNew :: Module -> HeapType -> Expression -> Expression -> Effect Expression

-- | `ref.null`: a null reference of the given (nullable) reference type. Useful
-- | as the initializer of a reference array whose slots are later overwritten.
foreign import refNull :: Module -> Type -> Effect Expression

-- | `array.new_fixed`: allocate an array of the heap type from the given
-- | elements.
foreign import arrayNewFixed :: Module -> HeapType -> Array Expression -> Effect Expression

-- | `array.get`: read element at `index` (of value type `elementType`) from
-- | `ref`. The boolean is sign extension, relevant only for packed elements.
foreign import arrayGet :: Module -> Expression -> Expression -> Type -> Boolean -> Effect Expression

-- | `array.set`: write `value` into element `index` of the (mutable) array
-- | `ref`. Used to back-patch mutually-recursive closures' environments.
foreign import arraySet :: Module -> Expression -> Expression -> Expression -> Effect Expression

-- | `array.len`: the element count of array `ref`, as an `i32`.
foreign import arrayLen :: Module -> Expression -> Effect Expression

-- | `array.copy`: copy `length` elements from `src` (at `srcIndex`) into `dest`
-- | (at `destIndex`). `dest` must be a mutable array.
foreign import arrayCopy
  :: Module -> Expression -> Expression -> Expression -> Expression -> Expression -> Effect Expression

-- | `ref.cast`: narrow `ref` to value type `ty` (traps on mismatch).
foreign import refCast :: Module -> Expression -> Type -> Effect Expression

-- | `ref.func`: a reference to the named function, typed by heap type `ht`.
foreign import refFunc :: Module -> String -> HeapType -> Effect Expression

-- | `call_ref`: indirect call through a typed function reference `target` (of
-- | function heap type `ht`) with the given operands. Non-tail.
foreign import callRef :: Module -> Expression -> Array Expression -> HeapType -> Effect Expression

foreign import addFunctionImpl
  :: Module
  -> String
  -> Type
  -> Type
  -> Array Type
  -> Expression
  -> Effect Function

-- | Add a function: `addFunction mod name params results varTypes body`.
-- | `params`/`results` are tuple types built with `createType`.
addFunction
  :: Module
  -> String
  -> Type
  -> Type
  -> Array Type
  -> Expression
  -> Effect Function
addFunction = addFunctionImpl

foreign import addFunctionExportImpl :: Module -> String -> String -> Effect Export

-- | Export an internal function under an external name.
addFunctionExport :: Module -> String -> String -> Effect Export
addFunctionExport = addFunctionExportImpl

foreign import setStartImpl :: Module -> Function -> Effect Unit

-- | Set the module's start function — run automatically once at instantiation
-- | (used to initialise CAF globals before any export runs; ADR 0006).
setStart :: Module -> Function -> Effect Unit
setStart = setStartImpl

foreign import addFunctionImportImpl :: Module -> String -> String -> String -> Type -> Type -> Effect Unit

-- | Declare an imported function: `addFunctionImport mod internalName
-- | externalModule externalBase params results`. The internal name is how the
-- | module's own code refers to it (e.g. in `call`); the external module/base
-- | name is what the host (or a merged module) must supply.
addFunctionImport :: Module -> String -> String -> String -> Type -> Type -> Effect Unit
addFunctionImport = addFunctionImportImpl

foreign import addGlobalImpl :: Module -> String -> Type -> Boolean -> Expression -> Effect Unit

-- | Add a (possibly mutable) module global: `addGlobal mod name type mutable
-- | init`. The init expression must be a constant expression — for our shared
-- | nullary constructors that is a `struct.new` of constant operands, which the
-- | GC proposal admits in global initializers.
addGlobal :: Module -> String -> Type -> Boolean -> Expression -> Effect Unit
addGlobal = addGlobalImpl

foreign import globalGetImpl :: Module -> String -> Type -> Effect Expression

-- | Read a module global: `globalGet mod name type`.
globalGet :: Module -> String -> Type -> Effect Expression
globalGet = globalGetImpl

foreign import globalSetImpl :: Module -> String -> Expression -> Effect Expression

-- | Write a module global: `globalSet mod name value` (a void statement; sequence it
-- | inside a `block` to follow it with a value).
globalSet :: Module -> String -> Expression -> Effect Expression
globalSet = globalSetImpl

foreign import optimizeImpl :: Module -> Effect Unit

optimize :: Module -> Effect Unit
optimize = optimizeImpl

foreign import runPassesImpl :: Module -> Array String -> Effect Unit

-- | Run a specific list of optimization passes (instead of the full `-O` pipeline) — e.g. just
-- | `remove-unused-module-elements` to DCE internalised exports cheaply (ADR 0037 Phase 3).
runPasses :: Module -> Array String -> Effect Unit
runPasses = runPassesImpl

foreign import validateImpl :: Module -> Effect Boolean

-- | Validate the module; `true` means it is well-formed.
validate :: Module -> Effect Boolean
validate = validateImpl

foreign import emitTextImpl :: Module -> Effect String

-- | Emit the module as WAT (the WebAssembly text format).
emitText :: Module -> Effect String
emitText = emitTextImpl

foreign import emitBinaryImpl :: Module -> Effect Uint8Array

-- | Emit the module as a wasm binary.
emitBinary :: Module -> Effect Uint8Array
emitBinary = emitBinaryImpl

foreign import readBinaryImpl :: Uint8Array -> Effect Module

-- | Read a wasm binary back into a `Module` (the inverse of `emitBinary`), for post-processing a
-- | merged wasm in-memory (e.g. internalising cross-module exports then re-optimising, ADR 0037).
readBinary :: Uint8Array -> Effect Module
readBinary = readBinaryImpl

foreign import removeExportImpl :: Module -> String -> Effect Unit

-- | Remove an export by its external name (internalise it). After `wasm-merge` resolves a
-- | cross-module function export, removing it lets the optimiser DCE the function if now unused.
removeExport :: Module -> String -> Effect Unit
removeExport = removeExportImpl