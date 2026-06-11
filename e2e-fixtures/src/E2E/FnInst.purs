module E2E.FnInst where

import Prelude

-- Functor ((->) r): map = composition  → (x*2)+1
fnMap :: Int -> Int
fnMap n = map (_ + 1) (_ * 2) n

-- Apply ((->) r): apply f g x = f x (g x)  → x + x*10 = 11x
fnApply :: Int -> Int
fnApply n = ((+) <*> (_ * 10)) n

-- Applicative ((->) r): pure = const  → 42
fnPure :: Int -> Int
fnPure n = (pure 42 :: Int -> Int) n

-- Bind ((->) r): bind m f x = f (m x) x  → 2x + x = 3x
fnBind :: Int -> Int
fnBind n = ((_ * 2) >>= (\m x -> m + x)) n

-- Monad do-notation on functions (Reader)  → (x+1) + (x*2) = 3x+1
fnDo :: Int -> Int
fnDo n =
  ( do
      a <- (_ + 1)
      b <- (_ * 2)
      pure (a + b)
  ) n

-- Category ((->)): identity
fnId :: Int -> Int
fnId n = identity n

-- Semigroupoid ((->)): >>> (composeFlipped)  → (x+1)*2
fnCompose :: Int -> Int
fnCompose n = ((_ + 1) >>> (_ * 2)) n
