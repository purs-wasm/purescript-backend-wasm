module E2E.IntConv where

import Prelude

import Data.Int (fromNumber, toNumber)
import Data.Maybe (fromMaybe)

-- Exercises `Data.Int.fromNumberImpl` (the private foreign behind `fromNumber`) as an
-- intrinsic: `fromNumber` applies the `Just` closure to the truncated `Int` when the
-- `Number` is an integer in range, else returns `Nothing`. The round-trip
-- `Int → Number → Maybe Int → Int` must recover the input.
roundtrip :: Int -> Int
roundtrip k = fromMaybe (-1) (fromNumber (toNumber k))
