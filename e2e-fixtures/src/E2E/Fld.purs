module E2E.Fld where

import Prelude
import Data.DivisionRing (recip)
import Data.Field (class Field)
import Data.Int (toNumber)

-- `recip` (DivisionRing): recip x * x == 1.0  (checked at integral x /= 0)
recipOk :: Int -> Int
recipOk a = if recip (toNumber a) * toNumber a == 1.0 then 1 else 0

-- A `Field`-constrained generic: `/` here is the EuclideanRing superclass pulled
-- out of the Field dictionary, so using it at `Number` forces the whole Field
-- instance (EuclideanRing + DivisionRing superclasses) to be constructed/linked.
fdiv :: forall a. Field a => a -> a -> a
fdiv a b = a / b

-- fdivOk a b = if fdiv a b * b == a then 1 else 0  (at Number)
fdivOk :: Int -> Int -> Int
fdivOk a b = if fdiv (toNumber a) (toNumber b) * toNumber b == toNumber a then 1 else 0
