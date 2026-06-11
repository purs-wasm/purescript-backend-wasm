-- Regression for #4: as-patterns (`name@pat`) at a clause/case head were silently not
-- matched (the alternative was dropped). Covers a head as-pattern over a deep cons, an
-- as-pattern on a constructor sub-binder, and a named scalar (literal as-pattern).
module E2E.AsPattern where

import Prelude

data L = N | C Int L

len :: L -> Int
len = case _ of
  N -> 0
  C _ rest -> 1 + len rest

sumL :: L -> Int
sumL = case _ of
  N -> 0
  C x rest -> x + sumL rest

build :: Int -> L
build n = if n == 0 then N else C n (build (n - 1))

-- (1) as-pattern at the clause head over a 3-deep cons (the exact #4 shape): bind the
--     whole list and return its length; lists shorter than 3 fall to the catch-all.
headAs :: Int -> Int
headAs n = case build n of
  whole@(C _ (C _ (C _ _))) -> len whole
  _ -> -1

-- (2) as-pattern on a constructor *sub-binder*: bind the tail and sum it.
subAs :: Int -> Int
subAs n = case build n of
  C _ tl@(C _ _) -> sumL tl
  _ -> -1

-- (3) named scalar (literal as-pattern): bind the matched literal.
litAs :: Int -> Int
litAs n = case n of
  z@0 -> z + 100
  _ -> n
