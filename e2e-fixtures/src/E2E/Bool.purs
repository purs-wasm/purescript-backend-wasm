module E2E.Bool where

import Prelude

-- && (conj) — two equalities AND-ed
conjf :: Int -> Int -> Int -> Int
conjf a b c = if (a == b) && (b == c) then 1 else 0

-- || (disj)
disjf :: Int -> Int -> Int
disjf a b = if (a == 0) || (b == 0) then 1 else 0

-- not
negf :: Int -> Int
negf a = if not (a == 0) then 1 else 0
