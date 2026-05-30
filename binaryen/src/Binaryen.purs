-- | Minimal FFI bindings to Binaryen.js.
-- |
-- | This is a thin, low-level layer: it mirrors the Binaryen API shape and
-- | leaves any higher-level IR-construction conveniences to callers. Anything
-- | that allocates into the module's arena or mutates the module is modelled
-- | as an `Effect`; pure type values (`i32`, `none`, ...) are not.
module Binaryen
  ( Module
  , Expression
  , Type
  , Function
  , Export
  , createModule
  , dispose
  , i32
  , i64
  , f32
  , f64
  , none
  , createType
  , localGet
  , localSet
  , block
  , call
  , i32Add
  , i32Sub
  , i32Mul
  , i32Const
  , addFunction
  , addFunctionExport
  , optimize
  , validate
  , emitText
  , emitBinary
  -- Wasm GC
  , HeapType
  , TypeBuilder
  , eqref
  , setFeaturesGC
  , typeBuilderCreate
  , typeBuilderSetStructType
  , typeBuilderSetArrayType
  , typeBuilderGetTempHeapType
  , typeBuilderGetTempRefType
  , typeBuilderBuildAndDispose
  , typeFromHeapType
  , structNew
  , structGet
  , arrayNewFixed
  , arrayGet
  , refCast
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

foreign import callImpl :: Module -> String -> Array Expression -> Type -> Effect Expression

-- | Call the internal function `target` with `operands`, yielding `returnType`.
call :: Module -> String -> Array Expression -> Type -> Effect Expression
call = callImpl

foreign import i32AddImpl :: Module -> Expression -> Expression -> Effect Expression

i32Add :: Module -> Expression -> Expression -> Effect Expression
i32Add = i32AddImpl

foreign import i32SubImpl :: Module -> Expression -> Expression -> Effect Expression

i32Sub :: Module -> Expression -> Expression -> Effect Expression
i32Sub = i32SubImpl

foreign import i32MulImpl :: Module -> Expression -> Expression -> Effect Expression

i32Mul :: Module -> Expression -> Expression -> Effect Expression
i32Mul = i32MulImpl

foreign import i32ConstImpl :: Module -> Int -> Effect Expression

i32Const :: Module -> Int -> Effect Expression
i32Const = i32ConstImpl

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

-- | `struct.new`: allocate a struct of the heap type, with field initializers
-- | given in field order.
foreign import structNew :: Module -> HeapType -> Array Expression -> Effect Expression

-- | `struct.get`: read field `index` (of value type `fieldType`) from `ref`.
-- | The boolean is the sign extension, relevant only for packed fields.
foreign import structGet :: Module -> Int -> Expression -> Type -> Boolean -> Effect Expression

-- | `array.new_fixed`: allocate an array of the heap type from the given
-- | elements.
foreign import arrayNewFixed :: Module -> HeapType -> Array Expression -> Effect Expression

-- | `array.get`: read element at `index` (of value type `elementType`) from
-- | `ref`. The boolean is sign extension, relevant only for packed elements.
foreign import arrayGet :: Module -> Expression -> Expression -> Type -> Boolean -> Effect Expression

-- | `ref.cast`: narrow `ref` to value type `ty` (traps on mismatch).
foreign import refCast :: Module -> Expression -> Type -> Effect Expression

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

foreign import optimizeImpl :: Module -> Effect Unit

optimize :: Module -> Effect Unit
optimize = optimizeImpl

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
