module PureScript.ExternsFile.Decoder.Utils
  ( asArray
  , asInt
  , readAt
  ) where

import Data.Either (Either(..))
import Data.Function.Uncurried (Fn2, Fn3, runFn2, runFn3)
import Foreign (Foreign)
import PureScript.ExternsFile.Decoder.Monad (DecodeError(..))

type DecodeFFIUtil =
  { "Left" :: forall a b. a -> Either a b
  , "Right" :: forall a b. b -> Either a b
  , "Unexpected" :: String -> DecodeError
  , "MissingValue" :: DecodeError
  }

decodeUtil :: DecodeFFIUtil
decodeUtil =
  { "Left": Left
  , "Right": Right
  , "MissingValue": MissingValue
  , "Unexpected": Unexpected
  }

foreign import asInt_ :: forall a. Fn3 DecodeFFIUtil a Foreign (Either DecodeError Int)

foreign import asArray_ :: Fn2 DecodeFFIUtil Foreign (Either DecodeError (Array Foreign))

foreign import readAt_ :: Fn3 DecodeFFIUtil Int Foreign (Either DecodeError Foreign)

asInt :: forall a. a -> Foreign -> Either DecodeError Int
asInt = runFn3 asInt_ decodeUtil

asArray :: Foreign -> Either DecodeError (Array Foreign)
asArray = runFn2 asArray_ decodeUtil

readAt :: Int -> Foreign -> Either DecodeError Foreign
readAt = runFn3 readAt_ decodeUtil