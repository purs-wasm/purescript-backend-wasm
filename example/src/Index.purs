module Index where

import Lib as L

fib :: Int -> Int
fib n' =
  let
    decr = (_ `L.subI` 1)
    go a b k =
      if k `L.eqI` 1 then a
      else go b (a `L.addI` b) (decr k)
  in
    go 1 1 n'