module E2E.Fab where

import Prelude

-- Functor: map / <$>
mapOk :: Int
mapOk = if map (_ + 1) [ 1, 2, 3 ] == [ 2, 3, 4 ] then 1 else 0

fmapOk :: Int
fmapOk = if ((_ * 2) <$> [ 1, 2, 3 ]) == [ 2, 4, 6 ] then 1 else 0

mapEmpty :: Int
mapEmpty = if map (_ + 1) ([] :: Array Int) == [] then 1 else 0

-- Apply: (+) <$> [1,2] <*> [10,20] = [11,21,12,22]
applyOk :: Int
applyOk = if ((+) <$> [ 1, 2 ] <*> [ 10, 20 ]) == [ 11, 21, 12, 22 ] then 1 else 0

-- Bind: flatMap
bindOk :: Int
bindOk = if ([ 1, 2, 3 ] >>= \x -> [ x, x * 10 ]) == [ 1, 10, 2, 20, 3, 30 ] then 1 else 0

bindEmpty :: Int
bindEmpty = if ([ 1, 2 ] >>= \_ -> ([] :: Array Int)) == [] then 1 else 0
