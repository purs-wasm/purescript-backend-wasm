module E2E.Cmp where

import Prelude

-- Eq: real `==` on Int (Eq dictionary -> eqIntImpl -> i32.eq)
isEq :: Int -> Int -> Int
isEq a b = if a == b then 1 else 0

-- Ord: `<` derived from `compare` (lessThan -> compare -> ordIntImpl, then a
-- constructor match on Ordering with a catch-all)
isLt :: Int -> Int -> Int
isLt a b = if a < b then 1 else 0

-- Ord: `compare` returning the Ordering ADT, matched LT/EQ/GT
cmp :: Int -> Int -> Int
cmp a b = case compare a b of
  LT -> 0
  EQ -> 1
  GT -> 2
