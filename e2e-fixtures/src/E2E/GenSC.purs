module E2E.GenSC where

import Prelude

import Data.Eq.Generic (genericEq)
import Data.Generic.Rep (class Generic)
import Data.Ord.Generic (genericCompare)
import Data.Show.Generic (genericShow)

data T = A | B Int | C Int Int

derive instance Generic T _

instance Eq T where
  eq = genericEq

instance Ord T where
  compare = genericCompare

instance Show T where
  show = genericShow

-- compare's Ordering mapped to Int (LT = 0, EQ = 1, GT = 2)
ord2int :: Ordering -> Int
ord2int o = case o of
  LT -> 0
  EQ -> 1
  GT -> 2

-- genericCompare: across-constructor order follows the Sum (Inl/Inr) nesting,
-- within a constructor it compares fields left to right (Product).
cmpAB :: Int
cmpAB = ord2int (compare A (B 0)) -- A's tag < B's tag => LT

cmpBA :: Int
cmpBA = ord2int (compare (B 0) A) -- => GT

cmpBBlt :: Int
cmpBBlt = ord2int (compare (B 1) (B 2)) -- same ctor, 1 < 2 => LT

cmpBBeq :: Int
cmpBBeq = ord2int (compare (B 5) (B 5)) -- => EQ

cmpCClt :: Int
cmpCClt = ord2int (compare (C 1 2) (C 1 3)) -- first field EQ, second LT => LT

cmpCCeq :: Int
cmpCCeq = ord2int (compare (C 7 8) (C 7 8)) -- => EQ

-- genericShow: nullary -> the bare constructor name; with args -> "(Ctor a b)"
-- (the constructor name from `reflectSymbol`, args joined by `intercalate " "`).
showA :: Int
showA = if show A == "A" then 1 else 0

showB :: Int
showB = if show (B 5) == "(B 5)" then 1 else 0

showC :: Int
showC = if show (C 1 2) == "(C 1 2)" then 1 else 0

showNeg :: Int
showNeg = if show (B (-3)) == "(B -3)" then 1 else 0
