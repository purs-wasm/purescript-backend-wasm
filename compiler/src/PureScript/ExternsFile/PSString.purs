module PureScript.ExternsFile.PSString where

import Prelude

import Data.Newtype (class Newtype)
import PureScript.ExternsFile.Decoder.Class (class Decode)
import PureScript.ExternsFile.Decoder.Newtype (newtypeDecoder)

-- | A PureScript string as the array of UTF-16 code units the compiler stores.
newtype PSString = PSString (Array Int)

derive instance Newtype PSString _
derive newtype instance Eq PSString
derive newtype instance Ord PSString

instance Show PSString where
  show _ = "(PSString <...>)"

instance Decode PSString where
  decoder = newtypeDecoder

foreign import unsafeUTF16ToString :: Array Int -> String
