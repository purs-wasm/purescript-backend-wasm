-- | A growable little-endian byte writer and a cursor reader: the low-level
-- | substrate for the MIR cache codec (`MiddleEnd.Serialize`). The mutable buffer
-- | lives behind FFI and is driven in `Effect`; the structural codec wraps these in
-- | a pure, total `encode` / `Either`-returning `decode`, so this module is internal
-- | to the `Serialize` subsystem and not exported beyond it.
-- |
-- | Integers are zigzag LEB128 (compact for the small magnitudes that dominate MIR),
-- | `Number` is 8-byte IEEE-754 little-endian, and `String` is a byte-length prefix
-- | followed by UTF-8. A `Reader` past end yields `undefined`; the structural decoder
-- | guards with `atEnd` and validates leaf reconstructions, surfacing corruption as a
-- | decode failure rather than a wrong tree.
module PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes
  ( Writer
  , Reader
  , newWriter
  , putU8
  , putInt
  , putNumber
  , putString
  , putBytes
  , finish
  , newReader
  , getU8
  , getInt
  , getNumber
  , getString
  , getBytes
  , atEnd
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Effect (Effect)

foreign import data Writer :: Type
foreign import data Reader :: Type

foreign import newWriter :: Effect Writer
foreign import putU8 :: Writer -> Int -> Effect Unit
foreign import putInt :: Writer -> Int -> Effect Unit
foreign import putNumber :: Writer -> Number -> Effect Unit
foreign import putString :: Writer -> String -> Effect Unit
foreign import putBytes :: Writer -> Uint8Array -> Effect Unit
foreign import finish :: Writer -> Effect Uint8Array

foreign import newReader :: Uint8Array -> Effect Reader
foreign import getU8 :: Reader -> Effect Int
foreign import getInt :: Reader -> Effect Int
foreign import getNumber :: Reader -> Effect Number
foreign import getString :: Reader -> Effect String
foreign import getBytes :: Reader -> Effect Uint8Array
foreign import atEnd :: Reader -> Effect Boolean
