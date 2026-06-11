module E2E.Euclid where

import Prelude
import Data.EuclideanRing (degree, div, mod)

-- Euclidean Int division: a `div` b (non-negative-remainder quotient)
divE :: Int -> Int -> Int
divE a b = a `div` b

-- Euclidean Int remainder: always in [0, |b|)
modE :: Int -> Int -> Int
modE a b = a `mod` b

-- degree a = min |a| maxInt
degreeE :: Int -> Int
degreeE a = degree a
