module PureScript.ExternsFile.Decoder.Class where

import Prelude

import Control.Monad.Except (runExceptT)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Foldable (foldMap)
import Data.Function.Uncurried (runFn2)
import Data.Identity (Identity(..))
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign (readBoolean, readInt, readString, renderForeignError)
import PureScript.ExternsFile.Decoder.Monad (DecodeError(..), Decoder(..), runDecoder)
import PureScript.ExternsFile.Decoder.Utils (asArray, asInt, readAt)

class Decode t where
  decoder :: Decoder t

instance decodeInt :: Decode Int where
  decoder = Decoder \fgn ->
    let
      Identity res = runExceptT (readInt fgn)
    in
      res # lmap (Unexpected <<< foldMap renderForeignError)

instance decodeString :: Decode String where
  decoder = Decoder \fgn ->
    let
      Identity res = runExceptT (readString fgn)
    in
      res # lmap (Unexpected <<< foldMap renderForeignError)

instance decodeBoolean :: Decode Boolean where
  decoder = Decoder \fgn ->
    let
      Identity res = runExceptT (readBoolean fgn)
    in
      res # lmap (Unexpected <<< foldMap renderForeignError)

instance decodeMaybe :: Decode a => Decode (Maybe a) where
  decoder = Decoder \fgn ->
    case readAt 0 fgn of
      Left MissingValue -> Right Nothing
      Left err -> Left err
      Right fgn' -> case runDecoder (decoder @a) fgn' of
        Right a -> pure (Just a)
        Left _ -> Just <$> runDecoder (decoder @a) fgn

instance decodeArray :: Decode a => Decode (Array a) where
  decoder = Decoder \fgn ->
    case asArray fgn of
      Left err -> Left err
      Right fgns -> traverse (runDecoder decoder) fgns

instance decodeEither :: (Decode a, Decode b) => Decode (Either a b) where
  decoder = Decoder \fgn ->
    case readAt 0 fgn >>= asInt "Either" of
      Left err -> Left (AtIndex 0 err)
      Right tag -> case tag of
        0 -> readAt 1 fgn >>= runDecoder (decoder @a) <#> Left
        1 -> readAt 1 fgn >>= runDecoder (decoder @b) <#> Right
        _ -> Left $ UnknownConstructorTag tag

instance decodeTuple :: (Decode a, Decode b) => Decode (Tuple a b) where
  decoder = Decoder \fgn -> ado
    a <- readAt 0 fgn >>= runDecoder decoder
    b <- readAt 1 fgn >>= runDecoder decoder
    in Tuple a b
