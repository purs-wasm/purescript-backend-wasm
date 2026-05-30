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
  , i32Add
  , i32Const
  , addFunction
  , addFunctionExport
  , optimize
  , validate
  , emitText
  , emitBinary
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

foreign import i32AddImpl :: Module -> Expression -> Expression -> Effect Expression

i32Add :: Module -> Expression -> Expression -> Effect Expression
i32Add = i32AddImpl

foreign import i32ConstImpl :: Module -> Int -> Effect Expression

i32Const :: Module -> Int -> Effect Expression
i32Const = i32ConstImpl

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
