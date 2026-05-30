module PureScript.ExternsFile.SourcePos where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)
import PureScript.ExternsFile.Decoder.Class (class Decode)
import PureScript.ExternsFile.Decoder.Generic (genericDecoder)

data SourcePos = SourcePos Int Int -- line, column

derive instance Eq SourcePos
derive instance Ord SourcePos
derive instance Generic SourcePos _
instance Show SourcePos where
  show = genericShow

instance Decode SourcePos where
  decoder = genericDecoder

data SourceSpan = SourceSpan String SourcePos SourcePos

derive instance Eq SourceSpan
derive instance Ord SourceSpan
derive instance Generic SourceSpan _
instance Show SourceSpan where
  show = genericShow

instance Decode SourceSpan where
  decoder = genericDecoder

type SourceAnn = Tuple SourceSpan (Array Comment)

data Comment
  = LineComment String
  | BlockComment String

derive instance Eq Comment
derive instance Ord Comment
derive instance Generic Comment _
instance Show Comment where
  show = genericShow

instance Decode Comment where
  decoder = genericDecoder
