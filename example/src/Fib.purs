module Example.Fib where

import Prelude

fib :: Int -> Int
fib n' =
  let
    decr = (_ - 1)
    go a b k =
      if k == 1 then a
      else go b (a + b) (decr k)
  in
    go 1 1 n'