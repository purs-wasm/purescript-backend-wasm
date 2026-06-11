module E2E.Sgp where

import Prelude

-- Internal observation foreigns (ArrayLength / ArrayIndex intrinsics), used to
-- inspect the result of the real `Prelude` `Array` `<>`.
foreign import lengthA :: forall a. Array a -> Int
foreign import indexA :: forall a. Array a -> Int -> Int

-- String `<>` (Data.Semigroup.concatString), checked by string equality.
strOk :: Int
strOk = if ("foo" <> "bar") == "foobar" then 1 else 0

-- Array `<>` (Data.Semigroup.concatArray): length of the concatenation.
arrLen :: Int
arrLen = lengthA ([ 1, 2, 3 ] <> [ 4, 5 ])

-- Array `<>`: the element at `i` of [10,20] <> [30,40] (= [10,20,30,40]).
arrAt :: Int -> Int
arrAt i = indexA ([ 10, 20 ] <> [ 30, 40 ]) i
