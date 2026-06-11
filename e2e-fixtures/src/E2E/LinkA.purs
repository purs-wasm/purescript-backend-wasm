module E2E.LinkA where

import E2E.LinkB (double, mkPair, fstP)

-- cross-module function call
quadruple :: Int -> Int
quadruple x = double (double x)

-- cross-module ADT construction + projection
firstOfPair :: Int -> Int
firstOfPair n = fstP (mkPair n 999)
