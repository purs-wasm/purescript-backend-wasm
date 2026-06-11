module E2E.Num where

import Prelude
import Data.Int (toNumber)

-- `Number` +, *, - checked against the Int result via `toNumber` and Number `==`
addOk :: Int -> Int -> Int
addOk a b = if toNumber a + toNumber b == toNumber (a + b) then 1 else 0

mulOk :: Int -> Int -> Int
mulOk a b = if toNumber a * toNumber b == toNumber (a * b) then 1 else 0

subOk :: Int -> Int -> Int
subOk a b = if toNumber a - toNumber b == toNumber (a - b) then 1 else 0

-- `Number` division, checked by (a / b) * b == a
divOk :: Int -> Int -> Int
divOk a b = if (toNumber a / toNumber b) * toNumber b == toNumber a then 1 else 0
