-- | A fixture of diverse `foreign import` signatures (plus one constrained,
-- | non-foreign value), for unit-testing the externs → calling-convention
-- | extraction edge cases (ADR 0014). Not an entry module; only its `externs.cbor`
-- | is used (copied into the compiler test fixtures).
module Example.Foreigns where

import Prelude

foreign import addOne :: Int -> Int
foreign import scale :: Int -> Number -> Number
foreign import maxInt :: Int
foreign import toChar :: Int -> Char
foreign import identityF :: forall a. a -> a
foreign import flag :: Boolean
foreign import shout :: String -> String

-- a constrained (non-foreign) value: exercises ConstrainedType in sig extraction
-- (purs forbids constraints on `foreign import`s themselves)
showIt :: forall a. Show a => a -> String
showIt = show
