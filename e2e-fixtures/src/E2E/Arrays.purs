module E2E.Arrays where

foreign import intAdd :: Int -> Int -> Int
foreign import lengthA :: forall a. Array a -> Int
foreign import indexA :: forall a. Array a -> Int -> a

nums :: Array Int
nums = [ 10, 20, 30 ]

countNums :: Int -> Int
countNums _ = lengthA nums

nthNum :: Int -> Int
nthNum i = indexA nums i

sumFirstTwo :: Int -> Int
sumFirstTwo _ = intAdd (indexA nums 0) (indexA nums 1)

-- a nested array, indexed twice
grid :: Array (Array Int)
grid = [ [ 1, 2 ], [ 3, 4 ] ]

cell :: Int -> Int
cell _ = indexA (indexA grid 1) 0
