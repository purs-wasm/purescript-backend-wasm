module E2E.Mnd where

import Prelude

-- a do-block on Array desugars to nested `bind` + `pure`
pairs :: Array Int
pairs = do
  x <- [ 1, 2 ]
  y <- [ 10, 20 ]
  pure (x + y)

pairsOk :: Int
pairsOk = if pairs == [ 11, 21, 12, 22 ] then 1 else 0

-- pure on its own (singleton)
pureOk :: Int
pureOk = if (pure 7 :: Array Int) == [ 7 ] then 1 else 0

-- wildcard bind (`_ <-`) in do
repl :: Array Int
repl = do
  _ <- [ 1, 2, 3 ]
  pure 0

replOk :: Int
replOk = if repl == [ 0, 0, 0 ] then 1 else 0
