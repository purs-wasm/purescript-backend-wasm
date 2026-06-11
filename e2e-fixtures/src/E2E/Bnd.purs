module E2E.Bnd where

import Prelude
import Data.Bounded (bottom, top)

-- Int bounds materialize as the i32 extremes (2147483647 / -2147483648).
topI :: Int
topI = top

bottomI :: Int
bottomI = bottom

-- The Ord superclass of Bounded: bottom < top.
intOrdered :: Int
intOrdered = if (bottom :: Int) < (top :: Int) then 1 else 0

-- Char bounds (code points 0 .. 0xFFFF), compared through Char's Ord.
charOrdered :: Int
charOrdered = if (bottom :: Char) < (top :: Char) then 1 else 0
