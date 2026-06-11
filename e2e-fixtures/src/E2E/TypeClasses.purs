module E2E.TypeClasses where

foreign import intAdd :: Int -> Int -> Int

class Addable a where
  plus :: a -> a -> a
  nil :: a

instance addableInt :: Addable Int where
  plus x y = intAdd x y
  nil = 0

double :: forall a. Addable a => a -> a
double x = plus x x

doubleInt :: Int -> Int
doubleInt n = double n

sumNil :: Int
sumNil = plus nil nil
