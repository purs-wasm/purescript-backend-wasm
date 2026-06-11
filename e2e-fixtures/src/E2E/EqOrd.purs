module E2E.EqOrd where

import Prelude

-- Boolean Eq
boolEqTT :: Int
boolEqTT = if true == true then 1 else 0

boolEqTF :: Int
boolEqTF = if true == false then 1 else 0

-- Boolean Ord (false < true)
boolLtFT :: Int
boolLtFT = if false < true then 1 else 0

boolLtTF :: Int
boolLtTF = if true < false then 1 else 0

boolGeTT :: Int
boolGeTT = if true >= true then 1 else 0

-- Number Ord — exercises the lt / eq / gt branches of unsafeCompareImpl
numLt :: Int
numLt = if 1.5 < 2.5 then 1 else 0

numGt :: Int
numGt = if 2.5 > 1.5 then 1 else 0

numGeEq :: Int
numGeEq = if 2.5 >= 2.5 then 1 else 0

numLeFalse :: Int
numLeFalse = if 2.5 <= 1.5 then 1 else 0

-- String Ord (lexicographic via $rt.strCmp)
strLt :: Int
strLt = if "abc" < "abd" then 1 else 0

strPrefix :: Int
strPrefix = if "ab" < "abc" then 1 else 0

strGe :: Int
strGe = if "abc" >= "abc" then 1 else 0

-- derived Eq on a constructor with fields (Int + String)
data Pair = Pair Int String

derive instance eqPair :: Eq Pair

pairEq :: Int
pairEq = if Pair 1 "a" == Pair 1 "a" then 1 else 0

pairNeq :: Int
pairNeq = if Pair 1 "a" == Pair 1 "b" then 1 else 0

-- Array Eq (length check + element-wise via the element-eq closure)
arrEq :: Int
arrEq = if [ 1, 2, 3 ] == [ 1, 2, 3 ] then 1 else 0

arrNeq :: Int
arrNeq = if [ 1, 2, 3 ] == [ 1, 2, 4 ] then 1 else 0

arrLenNeq :: Int
arrLenNeq = if [ 1, 2 ] == [ 1, 2, 3 ] then 1 else 0

arrStrEq :: Int
arrStrEq = if [ "a", "b" ] == [ "a", "b" ] then 1 else 0

-- Array Ord (lexicographic, prefix < longer)
arrLt :: Int
arrLt = if [ 1, 2 ] < [ 1, 3 ] then 1 else 0

arrPrefixLt :: Int
arrPrefixLt = if [ 1, 2 ] < [ 1, 2, 3 ] then 1 else 0

arrGe :: Int
arrGe = if [ 1, 2, 3 ] >= [ 1, 2, 3 ] then 1 else 0

arrGt :: Int
arrGt = if [ 2 ] > [ 1, 9, 9 ] then 1 else 0

-- multi-constructor derived Eq / Ord (the decision-tree path)
data Color = Red | Green | Blue

derive instance eqColor :: Eq Color
derive instance ordColor :: Ord Color

colorEq :: Int
colorEq = if Red == Red then 1 else 0

colorNeq :: Int
colorNeq = if Red == Green then 1 else 0

colorLt :: Int
colorLt = if Red < Blue then 1 else 0

colorGt :: Int
colorGt = if Blue > Green then 1 else 0

-- multiple constructors, some with fields
data Shape = Circle Int | Rect Int Int

derive instance eqShape :: Eq Shape

shapeEqC :: Int
shapeEqC = if Circle 3 == Circle 3 then 1 else 0

shapeNeqArg :: Int
shapeNeqArg = if Circle 3 == Circle 4 then 1 else 0

shapeNeqCtor :: Int
shapeNeqCtor = if Circle 3 == Rect 3 3 then 1 else 0

shapeEqR :: Int
shapeEqR = if Rect 2 3 == Rect 2 3 then 1 else 0
