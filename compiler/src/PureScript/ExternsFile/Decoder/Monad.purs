module PureScript.ExternsFile.Decoder.Monad where

import Prelude

import Control.Alt (class Alt)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Foreign (Foreign)

data DecodeError
  = UnknownConstructorTag Int
  | Unexpected String
  | NotSupported
  | AtIndex Int DecodeError
  | MissingValue

derive instance genericDecodeError :: Generic DecodeError _
instance showDecodeError :: Show DecodeError where
  show err = genericShow err

-- | A pure decoder from a CBOR-decoded `Foreign` value to `a`.
newtype Decoder a = Decoder (Foreign -> Either DecodeError a)

runDecoder :: forall a. Decoder a -> Foreign -> Either DecodeError a
runDecoder (Decoder d) = d

instance functorDecoder :: Functor Decoder where
  map f (Decoder k) = Decoder \fgn -> map f (k fgn)

instance applyDecoder :: Apply Decoder where
  apply (Decoder k1) (Decoder k2) = Decoder \fgn ->
    case k1 fgn of
      Left err -> Left err
      Right f -> f <$> k2 fgn

instance applicativeDecoder :: Applicative Decoder where
  pure a = Decoder \_ -> Right a

instance bindDecoder :: Bind Decoder where
  bind (Decoder k1) f = Decoder \fgn -> case k1 fgn of
    Left err -> Left err
    Right a -> let Decoder k2 = f a in k2 fgn

instance monadDecoder :: Monad Decoder

instance altDecoder :: Alt Decoder where
  alt (Decoder dec1) (Decoder dec2) = Decoder \fgn ->
    case dec1 fgn of
      Left _ -> dec2 fgn
      Right a -> Right a

fail :: forall a. DecodeError -> Decoder a
fail err = Decoder \_ -> Left err
