module E2E.LinkB where

foreign import intAdd :: Int -> Int -> Int

double :: Int -> Int
double x = intAdd x x

data Pair = Pair Int Int

mkPair :: Int -> Int -> Pair
mkPair = Pair

fstP :: Pair -> Int
fstP p = case p of
  Pair a _ -> a
